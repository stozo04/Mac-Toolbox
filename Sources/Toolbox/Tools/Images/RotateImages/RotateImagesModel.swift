import AppKit
import Observation

@MainActor @Observable
final class RotateImagesModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = RotateImagesModel()

    enum Status: BatchStatus {
        case waiting
        case rotating
        case done(RotateResult)
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
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Rotated Images", logCategory: "rotate-images", failureLog: "Image rotation failed",
                                     skippedBecause: "had no readable images", files: BatchFiles.images), outputParent: outputParent)
    }

    private(set) var selectedID: UUID?
    /// The selected photo with the current change applied, small enough to draw quickly.
    private(set) var preview: CGImage?
    private(set) var settings = RotateSettings()

    /// The selected photo before any change.
    private var basePreview: CGImage?

    var hasPending: Bool { queue.hasWaiting }
    var selected: Item? { items.first { $0.id == selectedID } }
    var canRotate: Bool { hasPending && !settings.isIdentity && !isRunning }

    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }

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
        basePreview = nil
        preview = nil
        guard let item = selected else { return }
        Task { [weak self] in
            // Decoding is heavy; keep it off the main thread.
            let image = await Task.detached(priority: .userInitiated) { ImageConverter.thumbnail(of: item.url, maxSize: 1200) }.value
            guard let self, selectedID == item.id else { return }
            basePreview = image
            refreshPreview()
        }
    }

    // MARK: Settings

    func rotateLeft() { change { $0.rotateLeft() } }
    func rotateRight() { change { $0.rotateRight() } }
    func flipHorizontal() { change { $0.flipHorizontal() } }
    func flipVertical() { change { $0.flipVertical() } }
    func reset() { change { $0.reset() } }

    private func change(_ edit: (inout RotateSettings) -> Void) {
        guard !isRunning else { return }
        edit(&settings)
        refreshPreview()
    }

    /// The same pixel mover that writes the copies, so the preview is what gets saved.
    private func refreshPreview() {
        preview = basePreview.flatMap { try? ImageRotator.apply(settings, to: $0) }
    }

    /// What a photo ends up as, e.g. "4032 × 3024 → 3024 × 4032".
    func outputSize(for size: PixelSize) -> PixelSize { settings.output(for: size) }

    // MARK: Rotating

    func rotate() {
        guard canRotate else { return }
        let settings = self.settings
        queue.run { item, folder, step in
            let result = try await step.detached(showing: .rotating) {
                try ImageRotator.rotate(source: item.url, settings: settings, into: folder)
            }
            Log.info("Image rotated", category: "rotate-images", ["kind": item.kind, "change": settings.summary])
            return .done(result)
        }
    }
}
