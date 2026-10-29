import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class AnnotateScreenshotModel {
    /// Shared so the picture and its marks survive switching to another tool and back.
    static let shared = AnnotateScreenshotModel()

    /// Everything undo has to bring back: the picture (it changes when cropped or replaced) and what is drawn on it.
    struct Document {
        var image: CGImage
        var annotations: [Annotation] = []
        /// What a saved file is called.
        var name: String

        var size: CGSize { CGSize(width: image.width, height: image.height) }
        func matches(_ other: Document) -> Bool { image === other.image && annotations == other.annotations }
    }

    private(set) var document: Document?
    private(set) var tool = AnnotationTool.arrow
    /// The style the next mark gets. Selecting a mark loads its style here, and changing it restyles the selected mark.
    var style = AnnotationStyle()
    private(set) var selectedID: UUID?
    /// While the Crop tool is picked: the part of the picture that stays, in image pixels.
    private(set) var cropRect: CGRect?
    /// The text being typed right now. The canvas shows an editor for it and leaves it out of the drawing.
    private(set) var editingID: UUID?
    var format = AnnotateFormat.png
    var jpegQuality = 0.9

    private(set) var notice: String?
    private(set) var savedURL: URL?
    private(set) var copied = false
    private(set) var isCapturing = false
    /// Counts every change to the picture or its marks; views redraw and re-render the thumbnail when it moves.
    private(set) var revision = 0

    let blurs = AnnotateBlurCache()
    /// Set by the canvas while a text editor is open; ends it and stores what was typed.
    var finishEditing: (() -> Void)?

    private var undoStack: [Document] = []
    private var redoStack: [Document] = []
    private var session: Document?
    private var lastStyleEdit: (id: UUID, at: Date)?
    private var colorBeforeHighlighter: AnnotationColor?
    private var copiedTask: Task<Void, Never>?

    var hasDocument: Bool { document != nil }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var annotations: [Annotation] { document?.annotations ?? [] }
    var selected: Annotation? { annotations.first { $0.id == selectedID } }
    var unit: CGFloat { document.map { AnnotateGeometry.unit(for: $0.size) } ?? 1 }
    var pixelSize: CGSize { document?.size ?? .zero }
    var isCropping: Bool { tool == .crop && cropRect != nil }
    var cropChanged: Bool { cropRect.map { $0 != fullRect } ?? false }
    private var fullRect: CGRect { CGRect(origin: .zero, size: pixelSize) }

    // MARK: Opening

    func open(url: URL) {
        guard let image = AnnotateScreenshot.load(url) else {
            notice = "macOS could not read \(url.lastPathComponent) as an image."
            return
        }
        replace(with: image, name: url.deletingPathExtension().lastPathComponent + " annotated")
    }

    func open(image: CGImage, name: String? = nil) {
        replace(with: image, name: name.map { $0 + " annotated" } ?? "Annotated " + AnnotateScreenshot.dateName())
    }

    /// Takes whatever picture the pasteboard holds. Returns false when there is none.
    @discardableResult
    func open(from pasteboard: NSPasteboard) -> Bool {
        guard let found = AnnotateScreenshot.image(from: pasteboard) else {
            notice = "There is no image on the clipboard."
            return false
        }
        open(image: found.image, name: found.name)
        return true
    }

    func paste() { open(from: .general) }

    /// A new picture replaces the old one, which stays one undo away.
    private func replace(with image: CGImage, name: String) {
        commitEditing()
        if let old = document { record(old) }
        document = Document(image: image, name: name)
        selectedID = nil
        cropRect = nil
        editingID = nil
        savedURL = nil
        notice = nil
        style = AnnotationStyle(color: style.color, width: style.width, shadow: style.shadow, textSize: style.textSize)
        if tool == .crop { tool = .arrow }
        touch()
    }

    func close() {
        commitEditing()
        document = nil
        undoStack = []
        redoStack = []
        selectedID = nil
        cropRect = nil
        savedURL = nil
        notice = nil
        touch()
    }

    // MARK: Capturing

    func capture() {
        guard !isCapturing else { return }
        commitEditing()
        isCapturing = true
        notice = nil
        Task {
            defer { isCapturing = false }
            do {
                if let image = try await AnnotateCapture.area() { open(image: image) }
            } catch {
                notice = error.localizedDescription
                Log.warning("Area capture failed", category: "annotate-screenshot", Log.details(error))
            }
        }
    }

    // MARK: Tools

    func setTool(_ new: AnnotationTool) {
        guard new != tool else { return }
        commitEditing()
        if tool == .highlight, let before = colorBeforeHighlighter {
            style.color = before
            colorBeforeHighlighter = nil
        }
        tool = new
        cropRect = nil
        if new != .select { select(nil) }
        switch new {
        case .highlight:
            // Marker is yellow unless the color was picked on purpose; the old color comes back afterwards.
            colorBeforeHighlighter = style.color
            style.color = .yellow
        case .crop:
            cropRect = document == nil ? nil : fullRect
        default:
            break
        }
        touch()
    }

    // MARK: Selecting

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        if id != nil { commitEditing() }
        selectedID = id
        if let a = selected {
            // The panel shows the mark's own style. The tool's blur and fill details stay as they were for kinds that lack them.
            style = a.style
        }
        touch()
    }

    /// Topmost mark at `point` (image pixels). `tolerance` is in pixels.
    func annotation(at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.last { AnnotateGeometry.hit($0, at: point, tolerance: tolerance, unit: unit) }
    }

    // MARK: Editing

    /// Marks the start of one gesture, so a whole drag is one undo step.
    func beginEdit() { session = document }

    func endEdit() {
        if let before = session, let now = document, !before.matches(now) { record(before) }
        session = nil
    }

    /// Runs one change as its own undo step.
    func perform(_ change: () -> Void) {
        guard let before = document else { return }
        change()
        if let now = document, !before.matches(now) { record(before) }
        touch()
    }

    func add(_ a: Annotation) {
        document?.annotations.append(a)
        touch()
    }

    func update(_ a: Annotation) {
        guard let i = annotations.firstIndex(where: { $0.id == a.id }) else { return }
        document?.annotations[i] = a
        touch()
    }

    func remove(_ id: UUID) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        let kind = annotations[i].kind
        document?.annotations.remove(at: i)
        if kind == .step { renumber() }
        if selectedID == id { selectedID = nil }
        touch()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        commitEditing()
        perform { remove(id) }
    }

    func duplicateSelected() {
        guard var copy = selected else { return }
        commitEditing()
        copy.id = UUID()
        copy = AnnotateGeometry.moved(copy, by: CGSize(width: 14 * unit, height: 14 * unit))
        if copy.kind == .step { copy.number = nextStepNumber }
        perform { add(copy) }
        select(copy.id)
    }

    func bringToFront() { reorder(toFront: true) }
    func sendToBack() { reorder(toFront: false) }

    private func reorder(toFront: Bool) {
        guard let a = selected, let i = annotations.firstIndex(where: { $0.id == a.id }) else { return }
        perform {
            document?.annotations.remove(at: i)
            if toFront { document?.annotations.append(a) } else { document?.annotations.insert(a, at: 0) }
            if a.kind == .step { renumber() }
        }
    }

    func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let a = selected else { return }
        perform { update(AnnotateGeometry.moved(a, by: CGSize(width: dx, height: dy))) }
    }

    /// The number the next step gets.
    var nextStepNumber: Int { (annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1 }

    /// Steps count 1, 2, 3 in the order they were placed, so deleting one closes the gap.
    private func renumber() {
        guard var list = document?.annotations else { return }
        var n = 0
        for i in list.indices where list[i].kind == .step {
            n += 1
            list[i].number = n
        }
        document?.annotations = list
    }

    /// Stores the text typed into a text mark. An empty text removes the mark.
    func commitText(_ text: String, for id: UUID) {
        defer { editingID = nil; touch() }
        guard let a = annotations.first(where: { $0.id == id }) else { return }
        if text.isEmpty {
            remove(id)
        } else {
            var copy = a
            copy.text = text
            update(copy)
        }
        endEdit()
    }

    /// A new text mark has already started its undo step (`beginEdit`); one that is being changed starts it here.
    func beginTextEditing(_ id: UUID) {
        if session == nil { beginEdit() }
        editingID = id
        touch()
    }

    /// Ends any text being typed, keeping it, so saving and copying never miss the last words.
    func commitEditing() {
        guard editingID != nil else { return }
        finishEditing?()
        editingID = nil
    }

    // MARK: Style

    /// Changes the style for what is drawn next and for the selected mark. Dragging a slider is one undo step.
    func restyle(_ change: (inout AnnotationStyle) -> Void) {
        change(&style)
        guard var a = selected else { return }
        a.style = style
        let now = Date()
        if lastStyleEdit?.id != a.id || now.timeIntervalSince(lastStyleEdit?.at ?? .distantPast) > 1 {
            if let before = document { record(before) }
        }
        lastStyleEdit = (a.id, now)
        update(a)
    }

    // MARK: Crop

    func setCrop(_ rect: CGRect) {
        guard tool == .crop else { return }
        cropRect = AnnotateGeometry.fitted(rect, in: pixelSize)
        touch()
    }

    func applyCrop() {
        guard let doc = document, let rect = cropRect?.integral.intersection(fullRect), rect.width >= 1, rect.height >= 1,
              rect != fullRect, let cropped = doc.image.cropping(to: rect) else {
            cancelCrop()
            return
        }
        record(doc)
        var next = doc
        next.image = cropped
        // Marks keep their place on the picture, so they move with the new corner.
        next.annotations = doc.annotations.map { AnnotateGeometry.moved($0, by: CGSize(width: -rect.minX, height: -rect.minY)) }
        document = next
        cropRect = nil
        tool = .select
        selectedID = nil
        touch()
    }

    func cancelCrop() {
        cropRect = nil
        tool = .select
        touch()
    }

    // MARK: Undo

    private func record(_ before: Document) {
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []
    }

    func undo() {
        commitEditing()
        guard let previous = undoStack.popLast(), let current = document else { return }
        redoStack.append(current)
        restore(previous)
    }

    func redo() {
        commitEditing()
        guard let next = redoStack.popLast(), let current = document else { return }
        undoStack.append(current)
        restore(next)
    }

    private func restore(_ doc: Document) {
        document = doc
        if selected == nil { selectedID = nil }
        cropRect = tool == .crop ? CGRect(origin: .zero, size: doc.size) : nil
        lastStyleEdit = nil
        touch()
    }

    // MARK: Output

    /// The finished picture at full size, or at `scale` for a thumbnail.
    func rendered(scale: CGFloat = 1, opaque: Bool? = nil) -> CGImage? {
        guard let doc = document else { return nil }
        return AnnotateRenderer.render(image: doc.image, annotations: doc.annotations, blurs: blurs, scale: scale, opaque: opaque ?? (format == .jpeg))
    }

    func copy() {
        commitEditing()
        guard let image = rendered(opaque: false), let png = try? AnnotateScreenshot.encode(image, as: .png, quality: 1) else {
            notice = AnnotateError.encodeFailed.localizedDescription
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        notice = nil
        copied = true
        copiedTask?.cancel()
        copiedTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { copied = false }
        }
        Log.info("Annotated image copied", category: "annotate-screenshot", ["marks": "\(annotations.count)"])
    }

    /// Saves a new file in Downloads. The original is never touched.
    func save() {
        commitEditing()
        guard let doc = document, let image = rendered() else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        do {
            savedURL = try AnnotateScreenshot.save(image, name: doc.name, format: format, quality: jpegQuality, into: downloads)
            notice = nil
            Log.info("Annotated image saved", category: "annotate-screenshot", ["format": format.rawValue, "marks": "\(doc.annotations.count)"])
        } catch {
            notice = error.localizedDescription
            Log.error("Annotated image save failed", category: "annotate-screenshot", Log.details(error, ["format": format.rawValue, "image_name": doc.name]))
        }
    }

    /// A file to drag into a chat or an email, in the chosen format.
    func dragFile() -> URL? {
        commitEditing()
        guard let doc = document, let image = rendered() else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Toolbox Annotated", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try? AnnotateScreenshot.save(image, name: doc.name, format: format, quality: jpegQuality, into: folder)
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func touch() { revision += 1 }

    // MARK: Keys

    /// Handles a key press while this tool is on screen. Returns true when the key was used.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""

        if flags.contains(.command) {
            guard !flags.contains(.option), !flags.contains(.control) else { return false }
            switch key.lowercased() {
            case "v": paste(); return true
            case "z": if flags.contains(.shift) { redo() } else { undo() }; return true
            case "c": guard hasDocument else { return false }; copy(); return true
            case "s": guard hasDocument else { return false }; save(); return true
            case "d": guard selected != nil else { return false }; duplicateSelected(); return true
            default: return false
            }
        }
        guard !flags.contains(.control), !flags.contains(.option) else { return false }

        switch event.keyCode {
        case 51, 117: // delete, forward delete
            guard selected != nil else { return false }
            deleteSelected()
            return true
        case 53: // escape
            if isCropping { cancelCrop() } else if selected != nil { select(nil) } else if tool != .select, hasDocument { setTool(.select) } else { return false }
            return true
        case 36, 76: // return, enter
            if isCropping { applyCrop(); return true }
            if let a = selected, a.kind == .text { NotificationCenter.default.post(name: .annotateEditSelectedText, object: a.id); return true }
            return false
        case 123, 124, 125, 126: // arrows
            guard selected != nil else { return false }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: nudge(-step, 0)
            case 124: nudge(step, 0)
            case 125: nudge(0, step)
            default: nudge(0, -step)
            }
            return true
        default:
            break
        }
        guard hasDocument, let character = key.first, !flags.contains(.shift) || character.isLetter, let picked = AnnotationTool(key: character) else { return false }
        setTool(picked)
        return true
    }
}

extension Notification.Name {
    /// Asks the canvas to open the editor for the selected text.
    static let annotateEditSelectedText = Notification.Name("AnnotateEditSelectedText")
}
