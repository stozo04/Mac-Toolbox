import AppKit
import Observation

@MainActor @Observable
final class RotateImagesModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = RotateImagesModel()

    enum Status: Equatable {
        case waiting
        case rotating
        case done(RotateResult)
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
    /// The selected photo with the current change applied, small enough to draw quickly.
    private(set) var preview: CGImage?
    private(set) var isRunning = false
    private(set) var folder: URL?
    private(set) var notice: String?
    private(set) var settings = RotateSettings()

    /// The selected photo before any change.
    private var basePreview: CGImage?
    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting } }
    var selected: Item? { items.first { $0.id == selectedID } }
    var canRotate: Bool { hasPending && !settings.isIdentity && !isRunning }

    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }

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
        isRunning = true
        for i in items.indices { if case .failed = items[i].status { items[i].status = .waiting } }
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Rotated Images")
        self.folder = folder
        let settings = self.settings
        task = Task { [weak self] in
            guard let self else { return }
            for item in items where item.status == .waiting {
                if Task.isCancelled { break }
                update(item.id, .rotating)
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<RotateResult, Error> in
                    Result { try ImageRotator.rotate(source: item.url, settings: settings, into: folder) }
                }.value
                switch outcome {
                case .success(let result):
                    update(item.id, .done(result))
                    Log.info("Image rotated", category: "rotate-images", ["kind": item.kind, "change": settings.summary])
                case .failure(let error):
                    update(item.id, .failed(error.localizedDescription))
                    Log.error("Image rotation failed", category: "rotate-images", Log.details(error, file: item.url))
                }
            }
            for i in items.indices where items[i].status == .rotating { items[i].status = .waiting }
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
