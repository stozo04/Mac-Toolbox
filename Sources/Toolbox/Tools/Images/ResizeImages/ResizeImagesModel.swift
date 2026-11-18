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
final class ResizeImagesModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = ResizeImagesModel()

    enum Status: BatchStatus {
        case waiting
        case resizing
        case done(ImageResizeResult)
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Item: BatchItem {
        let id = UUID()
        let url: URL
        let bytes: Int64
        /// As shown, turned upright.
        let size: PixelSize
        var status = Status.waiting

        /// "HEIC", "JPEG"... from the file's extension.
        var kind: String { ImageFormat.name(forExtension: url.pathExtension) }
    }

    let queue: BatchQueue<Item>

    init(outputParent: URL? = nil) {
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Resized Images", logCategory: "resize-images", failureLog: "Image resize failed",
                                     skippedBecause: "had no readable images", files: BatchFiles.images), outputParent: outputParent)
    }
    private(set) var selectedID: UUID?
    /// The selected photo, small enough to draw quickly.
    private(set) var previewImage: CGImage?

    var settings = ImageResizeSettings()

    var hasPending: Bool { queue.hasWaiting }
    var selected: Item? { items.first { $0.id == selectedID } }

    private var results: [ImageResizeResult] {
        items.compactMap { if case .done(let r) = $0.status { r } else { nil } }
    }
    var doneCount: Int { results.count }

    func outputSize(for size: PixelSize) -> PixelSize { ImageResizePlan.output(for: size, settings: settings) }

    // MARK: Queue

    func add(_ urls: [URL]) {
        queue.add(urls) { url in
            ImageResizer.pixelSize(of: url).map { Item(url: url, bytes: BatchFiles.bytes(of: url), size: $0) }
        }
        if selected == nil, let first = items.first { select(first.id) }
    }

    func remove(_ id: UUID) {
        guard queue.remove(id) else { return }
        if selectedID == id { select(items.first?.id) }
    }

    func clear() {
        queue.clear()
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
        guard hasPending else { return }
        let settings = self.settings
        queue.run { item, folder, step in
            let result = try await step.detached(showing: .resizing) {
                try ImageResizer.resize(source: item.url, settings: settings, into: folder)
            }
            Log.info("Image resized", category: "resize-images", ["kind": item.kind, "mode": settings.mode.rawValue])
            return .done(result)
        }
    }
}
