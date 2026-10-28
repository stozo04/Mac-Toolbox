import AppKit
import Observation

/// The eight grips around the picture in the preview.
enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    /// -1 = grips the left side, 1 = the right side, 0 = leaves the width alone.
    var dx: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .topRight, .right, .bottomRight: 1
        case .top, .bottom: 0
        }
    }

    /// -1 = grips the top, 1 = the bottom, 0 = leaves the height alone.
    var dy: Int {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .bottomLeft, .bottom, .bottomRight: 1
        case .left, .right: 0
        }
    }
}

@MainActor @Observable
final class ResizeImagesModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = ResizeImagesModel()

    enum Status: Equatable {
        case waiting
        case resizing
        case done(ImageResizeResult)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int64
        /// As shown, turned upright.
        let size: PixelSize
        var status = Status.waiting

        /// "HEIC", "JPEG"... from the file's extension.
        var kind: String { ImageFormat.name(forExtension: url.pathExtension) }
    }

    private(set) var items: [Item] = []
    private(set) var selectedID: UUID?
    /// The selected photo, small enough to draw quickly.
    private(set) var previewImage: CGImage?
    private(set) var isRunning = false
    private(set) var folder: URL?
    private(set) var notice: String?

    var settings = ImageResizeSettings()

    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting } }
    var selected: Item? { items.first { $0.id == selectedID } }

    private var results: [ImageResizeResult] {
        items.compactMap { if case .done(let r) = $0.status { r } else { nil } }
    }
    var doneCount: Int { results.count }

    func outputSize(for size: PixelSize) -> PixelSize { ImageResizePlan.output(for: size, settings: settings) }

    // MARK: Queue

    /// Adds images; folders are searched for images inside them.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += BatchFiles.images(in: url)
            if found.count == before { skipped += 1 }
        }
        var known = Set(items.map { BatchFiles.identity($0.url) })
        for url in found where known.insert(BatchFiles.identity(url)).inserted {
            guard let size = ImageResizer.pixelSize(of: url) else { skipped += 1; continue }
            let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            items.append(Item(url: url, bytes: bytes, size: size))
        }
        notice = skipped == 0 ? nil : "\(skipped) item(s) had no readable images and were skipped."
        if selected == nil, let first = items.first { select(first.id) }
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
        if selectedID == id { select(items.first?.id) }
    }

    func clear() {
        task?.cancel()
        items = []
        folder = nil
        notice = nil
        isRunning = false
        select(nil)
    }

    func select(_ id: UUID?) {
        selectedID = id
        previewImage = nil
        guard let item = selected else { return }
        Task { [weak self] in
            // Decoding is heavy; keep it off the main thread.
            let image = await Task.detached(priority: .userInitiated) { ImageConverter.thumbnail(of: item.url, maxSize: 1600) }.value
            guard let self, selectedID == item.id else { return }
            previewImage = image
        }
    }

    // MARK: Settings

    func setWidth(_ value: Int) {
        settings.width = Self.clamp(value)
        guard settings.keepProportions, let o = selected?.size else { return }
        settings.height = Self.clamp(Int((Double(settings.width) * Double(o.height) / Double(o.width)).rounded()))
    }

    func setHeight(_ value: Int) {
        settings.height = Self.clamp(value)
        guard settings.keepProportions, let o = selected?.size else { return }
        settings.width = Self.clamp(Int((Double(settings.height) * Double(o.width) / Double(o.height)).rounded()))
    }

    func setKeepProportions(_ on: Bool) {
        settings.keepProportions = on
        if on { setWidth(settings.width) }
    }

    /// The photo's grips were dragged: `width` and `height` are where the cursor says its sides should be, in the photo's own pixels.
    /// Whatever the mode is, the value it uses follows, so the numbers in the options panel always match what is on screen.
    func drag(_ handle: ResizeHandle, width: Double, height: Double) {
        guard !isRunning, let o = selected?.size else { return }
        let (ow, oh) = (Double(o.width), Double(o.height))
        var grows = false
        if settings.mode != .size || settings.keepProportions {
            // One factor for both sides. A corner follows whichever way the cursor leans along the photo's diagonal.
            let factor: Double
            switch (handle.dx != 0, handle.dy != 0) {
            case (true, false): factor = width / ow
            case (false, true): factor = height / oh
            default: factor = (width * ow + height * oh) / (ow * ow + oh * oh)
            }
            switch settings.mode {
            case .percentage:
                settings.percent = min(max(Int((factor * 100).rounded()), ImageResizeSettings.percentRange.lowerBound), ImageResizeSettings.percentRange.upperBound)
            case .longestSide:
                settings.longestSide = Self.clamp(Int((factor * Double(o.longest)).rounded()))
                grows = factor > 1
            case .size:
                settings.width = Self.clamp(Int((factor * ow).rounded()))
                settings.height = Self.clamp(Int((factor * oh).rounded()))
                grows = factor > 1
            }
        } else {
            if handle.dx != 0 { settings.width = Self.clamp(Int(width.rounded())) }
            if handle.dy != 0 { settings.height = Self.clamp(Int(height.rounded())) }
            grows = Double(settings.width) > ow || Double(settings.height) > oh
        }
        // Pulling a photo bigger than it is means "make it bigger": switch Enlarge on so the picture follows the cursor.
        if grows { settings.enlarge = true }
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 1), ImageResizeSettings.maxPixels) }

    // MARK: Resizing

    func resize() {
        guard !isRunning, hasPending else { return }
        isRunning = true
        for i in items.indices { if case .failed = items[i].status { items[i].status = .waiting } }
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Resized Images")
        self.folder = folder
        let settings = self.settings
        task = Task { [weak self] in
            guard let self else { return }
            for item in items where item.status == .waiting {
                if Task.isCancelled { break }
                update(item.id, .resizing)
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ImageResizeResult, Error> in
                    Result { try ImageResizer.resize(source: item.url, settings: settings, into: folder) }
                }.value
                switch outcome {
                case .success(let result):
                    update(item.id, .done(result))
                    Log.info("Image resized", category: "resize-images", ["kind": item.kind, "mode": settings.mode.rawValue])
                case .failure(let error):
                    update(item.id, .failed(error.localizedDescription))
                    Log.error("Image resize failed", category: "resize-images", ["reason": "\((error as NSError).domain) \((error as NSError).code)"])
                }
            }
            for i in items.indices where items[i].status == .resizing { items[i].status = .waiting }
            isRunning = false
        }
    }

    func cancel() { task?.cancel() }

    private func update(_ id: UUID, _ status: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func revealFolder() { if let folder { NSWorkspace.shared.open(folder) } }
}
