import AppKit
import SwiftUI

/// The picture with its marks. Pick a tool and drag on the picture; with Select, click a mark to move it or drag its
/// handles. What is drawn here comes from the same renderer that saves the file.
struct AnnotateCanvas: NSViewRepresentable {
    let model: AnnotateScreenshotModel
    /// Changes whenever anything on screen should be drawn again.
    let revision: Int

    func makeNSView(context: Context) -> AnnotateCanvasView { AnnotateCanvasView(model: model) }

    func updateNSView(_ view: AnnotateCanvasView, context: Context) { view.refresh() }
}

@MainActor
final class AnnotateCanvasView: NSView, NSTextViewDelegate {
    private let model: AnnotateScreenshotModel

    /// What the current mouse gesture is doing, decided where it started.
    private enum Gesture {
        /// A press that may become a new mark once the pointer has really moved.
        case pending(tool: AnnotationTool, start: CGPoint)
        case create(id: UUID, tool: AnnotationTool, start: CGPoint)
        case pen(id: UUID)
        case move(id: UUID, original: Annotation, start: CGPoint)
        case handle(id: UUID, handle: AnnotateGeometry.Handle, original: Annotation)
        case cropNew(start: CGPoint)
        case cropMove(original: CGRect, start: CGPoint)
        case cropHandle(AnnotateGeometry.Handle, original: CGRect)
    }

    private var gesture: Gesture?
    private var editor: AnnotateTextView?
    private var editedID: UUID?
    private var observer: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(model: AnnotateScreenshotModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .png, .tiff])
        observer = NotificationCenter.default.addObserver(forName: .annotateEditSelectedText, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            MainActor.assumeIsolated { self?.beginEditing(id) }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func refresh() {
        // The editor goes away when something else (a tool change, saving) ended the typing.
        if editor != nil, model.editingID != editedID { closeEditor() }
        layoutEditor()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        layoutEditor()
    }

    // MARK: Geometry

    private var imageSize: CGSize { model.pixelSize }

    /// Points on screen per image pixel, and where the picture's top left corner sits.
    private var placement: (scale: CGFloat, origin: CGPoint) {
        let size = imageSize
        guard size.width > 0, size.height > 0 else { return (1, .zero) }
        let inset: CGFloat = 22
        let available = CGSize(width: max(bounds.width - inset * 2, 1), height: max(bounds.height - inset * 2, 1))
        let scale = min(available.width / size.width, available.height / size.height, 3)
        return (scale, CGPoint(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2))
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let (scale, origin) = placement
        return CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let (scale, origin) = placement
        return CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let (scale, origin) = placement
        return CGRect(x: origin.x + r.minX * scale, y: origin.y + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    /// Image pixels that cover `points` points on screen: how close a click has to be.
    private func pixels(_ points: CGFloat) -> CGFloat { points / max(placement.scale, 0.0001) }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), imageSize.width), y: min(max(p.y, 0), imageSize.height))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let doc = model.document else { return }
        let (scale, origin) = placement
        let frame = toView(CGRect(origin: .zero, size: doc.size))

        // A hairline and a soft shadow lift the picture off the card.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: CGColor(gray: 0, alpha: 0.3))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(frame)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: frame)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale, y: scale)
        AnnotateRenderer.draw(image: doc.image, annotations: doc.annotations, blurs: model.blurs, in: ctx, scale: scale, baseIsFlipped: true, skipping: model.editingID)
        ctx.restoreGState()

        NSColor.white.withAlphaComponent(0.12).setStroke()
        NSBezierPath(rect: frame.insetBy(dx: -0.5, dy: -0.5)).stroke()

        if let crop = model.cropRect, model.tool == .crop { drawCrop(crop, frame: frame) }
        if model.tool != .crop, let a = model.selected, model.editingID != a.id { drawSelection(of: a) }
    }

    private func drawSelection(of a: Annotation) {
        let accent = NSColor.controlAccentColor
        let handles = AnnotateGeometry.handles(of: a)
        if handles.isEmpty || a.kind == .text || a.kind == .step || a.kind == .pen {
            let outline = toView(AnnotateGeometry.bounds(of: a, unit: model.unit)).insetBy(dx: -3, dy: -3)
            let path = NSBezierPath(roundedRect: outline, xRadius: 4, yRadius: 4)
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.lineWidth = 1.25
            accent.setStroke()
            path.stroke()
        } else if !a.kind.isLine {
            let path = NSBezierPath(rect: toView(a.box))
            path.lineWidth = 1
            accent.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
        for (_, point) in handles { drawGrip(at: toView(point), round: a.kind.isLine) }
    }

    private func drawGrip(at p: CGPoint, round: Bool) {
        let rect = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
        let path = round ? NSBezierPath(ovalIn: rect) : NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
        NSColor.white.setFill()
        path.fill()
        path.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawCrop(_ crop: CGRect, frame: CGRect) {
        let area = toView(crop)
        let dim = NSBezierPath(rect: frame)
        dim.append(NSBezierPath(rect: area))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        dim.fill()

        NSColor.white.withAlphaComponent(0.35).setStroke()
        for i in 1...2 {
            let f = CGFloat(i) / 3
            let v = NSBezierPath(), h = NSBezierPath()
            v.move(to: CGPoint(x: area.minX + area.width * f, y: area.minY)); v.line(to: CGPoint(x: area.minX + area.width * f, y: area.maxY))
            h.move(to: CGPoint(x: area.minX, y: area.minY + area.height * f)); h.line(to: CGPoint(x: area.maxX, y: area.minY + area.height * f))
            v.lineWidth = 0.75; h.lineWidth = 0.75
            v.stroke(); h.stroke()
        }
        let border = NSBezierPath(rect: area)
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()
        for (_, point) in AnnotateGeometry.handles(of: crop) { drawGrip(at: toView(point), round: false) }

        let label = NSAttributedString(string: "\(Int(crop.width.rounded())) × \(Int(crop.height.rounded()))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        let box = CGRect(x: area.midX - size.width / 2 - 7, y: min(area.maxY + 8, bounds.height - size.height - 8), width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        label.draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard model.hasDocument else { return }
        // A click away from the text being typed ends the typing first.
        model.commitEditing()
        let point = toImage(convert(event.locationInWindow, from: nil))
        let tool = model.tool
        model.beginEdit()

        if tool == .crop {
            beginCrop(at: clamped(point))
            return
        }
        let slack = pixels(7)
        // The grips of the selected mark work with every tool.
        if let a = model.selected, let h = AnnotateGeometry.handle(at: point, in: AnnotateGeometry.handles(of: a), radius: pixels(9)) {
            gesture = .handle(id: a.id, handle: h, original: a)
            return
        }
        if tool == .select {
            if let hit = model.annotation(at: point, tolerance: slack) {
                model.select(hit.id)
                if event.clickCount == 2, hit.kind == .text {
                    gesture = nil
                    beginEditing(hit.id)
                    return
                }
                gesture = .move(id: hit.id, original: hit, start: point)
            } else {
                model.select(nil)
            }
            return
        }

        switch tool {
        case .text:
            if let hit = model.annotation(at: point, tolerance: slack), hit.kind == .text {
                model.select(hit.id)
                beginEditing(hit.id)
            } else {
                let a = makeAnnotation(.text, at: clamped(point))
                model.add(a)
                model.select(a.id)
                beginEditing(a.id)
            }
        case .step:
            var a = makeAnnotation(.step, at: clamped(point))
            a.number = model.nextStepNumber
            model.add(a)
            model.select(a.id)
            gesture = .move(id: a.id, original: a, start: point)
        case .pen:
            var a = makeAnnotation(.pen, at: clamped(point))
            a.points = [clamped(point)]
            model.add(a)
            model.select(a.id)
            gesture = .pen(id: a.id)
        default:
            model.select(nil)
            gesture = .pending(tool: tool, start: clamped(point))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard model.hasDocument, let gesture else { return }
        let raw = convert(event.locationInWindow, from: nil)
        let point = toImage(raw)
        let constrain = event.modifierFlags.contains(.shift)

        switch gesture {
        case .pending(let tool, let start):
            let end = clamped(point)
            let moved = hypot(end.x - start.x, end.y - start.y) * placement.scale
            guard moved >= 3 else { return }
            var a = makeAnnotation(tool, at: start)
            a.end = constrain ? clamped(AnnotateGeometry.constrained(end, from: start, for: tool)) : end
            model.add(a)
            model.select(a.id)
            self.gesture = .create(id: a.id, tool: tool, start: start)
        case .create(let id, let tool, let start):
            guard var a = model.annotations.first(where: { $0.id == id }) else { return }
            let end = clamped(point)
            a.end = constrain ? clamped(AnnotateGeometry.constrained(end, from: start, for: tool)) : end
            model.update(a)
        case .pen(let id):
            guard var a = model.annotations.first(where: { $0.id == id }) else { return }
            let p = clamped(point)
            if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) * placement.scale < 1.5 { return }
            a.points.append(p)
            model.update(a)
        case .move(_, let original, let start):
            // The mark follows the pointer but never leaves the picture entirely.
            var delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            let box = AnnotateGeometry.bounds(of: original, unit: model.unit)
            delta.width = min(max(delta.width, -box.maxX + 4), imageSize.width - box.minX - 4)
            delta.height = min(max(delta.height, -box.maxY + 4), imageSize.height - box.minY - 4)
            model.update(AnnotateGeometry.moved(original, by: delta))
        case .handle(_, let handle, let original):
            model.update(AnnotateGeometry.resized(original, handle: handle, to: clamped(point), constrain: constrain))
        case .cropNew(let start):
            let end = clamped(point)
            model.setCrop(AnnotateGeometry.rect(from: start, to: constrain ? clamped(AnnotateGeometry.constrained(end, from: start, for: .crop)) : end))
        case .cropMove(let original, let start):
            var moved = original
            moved.origin = CGPoint(x: original.minX + point.x - start.x, y: original.minY + point.y - start.y)
            model.setCrop(moved)
        case .cropHandle(let handle, let original):
            model.setCrop(AnnotateGeometry.resized(original, handle: handle, to: clamped(point)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            // A text being typed keeps its undo step open until the typing ends.
            if model.editingID == nil { model.endEdit() }
        }
        guard case .create(let id, let tool, _)? = gesture, let a = model.annotations.first(where: { $0.id == id }) else { return }
        // A box or line too small to be on purpose is a stray click.
        let size = hypot(a.end.x - a.start.x, a.end.y - a.start.y) * placement.scale
        if size < 3 || (tool.isBox && (a.box.width * placement.scale < 3 || a.box.height * placement.scale < 3)) {
            model.remove(id)
        } else if tool.isBox {
            var normal = a
            normal.start = a.box.origin
            normal.end = CGPoint(x: a.box.maxX, y: a.box.maxY)
            model.update(normal)
        }
    }

    private func beginCrop(at point: CGPoint) {
        guard let crop = model.cropRect else { return }
        let slack = pixels(9)
        if let h = AnnotateGeometry.handle(at: point, in: AnnotateGeometry.handles(of: crop), radius: slack) {
            gesture = .cropHandle(h, original: crop)
        } else if crop.contains(point), crop != CGRect(origin: .zero, size: imageSize) {
            gesture = .cropMove(original: crop, start: point)
        } else {
            gesture = .cropNew(start: point)
        }
    }

    private func makeAnnotation(_ kind: AnnotationTool, at p: CGPoint) -> Annotation {
        Annotation(kind: kind, start: p, end: p, style: model.style)
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { cursor(at: convert(event.locationInWindow, from: nil)).set() }
    override func cursorUpdate(with event: NSEvent) { cursor(at: convert(event.locationInWindow, from: nil)).set() }

    private func cursor(at viewPoint: CGPoint) -> NSCursor {
        guard model.hasDocument, editor == nil else { return .arrow }
        let point = toImage(viewPoint)
        guard CGRect(origin: .zero, size: imageSize).insetBy(dx: -pixels(10), dy: -pixels(10)).contains(point) else { return .arrow }

        if model.tool == .crop, let crop = model.cropRect {
            if let h = AnnotateGeometry.handle(at: point, in: AnnotateGeometry.handles(of: crop), radius: pixels(9)) { return Self.cursor(for: h) }
            return crop.contains(point) && model.cropChanged ? .openHand : .crosshair
        }
        if let a = model.selected, let h = AnnotateGeometry.handle(at: point, in: AnnotateGeometry.handles(of: a), radius: pixels(9)) {
            return Self.cursor(for: h)
        }
        switch model.tool {
        case .select: return model.annotation(at: point, tolerance: pixels(7)) != nil ? .openHand : .arrow
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    private static func cursor(for handle: AnnotateGeometry.Handle) -> NSCursor {
        switch handle {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        default: .crosshair
        }
    }

    // MARK: Text

    private func beginEditing(_ id: UUID) {
        guard let a = model.annotations.first(where: { $0.id == id }), a.kind == .text else { return }
        closeEditor()
        model.select(id)
        model.beginTextEditing(id)
        let view = AnnotateTextView(frame: .zero)
        view.delegate = self
        view.string = a.text
        view.onFinish = { [weak self] in self?.window?.makeFirstResponder(self) }
        editor = view
        editedID = id
        model.finishEditing = { [weak self] in self?.endEditing() }
        addSubview(view)
        layoutEditor()
        window?.makeFirstResponder(view)
        view.selectAll(nil)
        needsDisplay = true
    }

    /// Places the editor exactly over the text, so typing looks the same as the result.
    private func layoutEditor() {
        guard let editor, let id = editedID, let a = model.annotations.first(where: { $0.id == id }) else { return }
        let (scale, _) = placement
        let font = NSFont.systemFont(ofSize: CGFloat(a.style.textSize) * model.unit * scale, weight: .semibold)
        editor.font = font
        editor.textColor = a.style.color.nsColor
        editor.insertionPointColor = a.style.color.nsColor
        if let layout = editor.layoutManager, let container = editor.textContainer {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).size
            let origin = toView(a.start)
            editor.frame = CGRect(x: origin.x, y: origin.y, width: max(used.width + 6, font.pointSize), height: max(used.height, font.boundingRectForFont.height))
        }
    }

    func textDidChange(_ notification: Notification) {
        layoutEditor()
        needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) { endEditing() }

    /// Stores the typed text and takes the editor away.
    private func endEditing() {
        guard let editor, let id = editedID else { return }
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        closeEditor()
        model.commitText(text, for: id)
        needsDisplay = true
    }

    private func closeEditor() {
        guard let editor else { return }
        editor.delegate = nil
        editor.removeFromSuperview()
        self.editor = nil
        editedID = nil
        model.finishEditing = nil
        if window?.firstResponder === editor || window?.firstResponder == nil { window?.makeFirstResponder(self) }
    }

    // MARK: Dropping

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { model.open(from: sender.draggingPasteboard) }
}

/// The box you type a text mark into. Return finishes; Shift-Return starts a new line.
final class AnnotateTextView: NSTextView {
    var onFinish: (() -> Void)?

    override init(frame: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 10_000, height: 10_000))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isHorizontallyResizable = true
        isVerticallyResizable = true
        textContainerInset = .zero
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) {
            onFinish?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onFinish?() }
}
