import AppKit
import Observation

@MainActor @Observable
final class RemoveBackgroundModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = RemoveBackgroundModel()

    enum Status: BatchStatus {
        case waiting
        case cutting
        case done(RemoveBackgroundResult)
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Item: BatchItem {
        let id = UUID()
        let url: URL
        let bytes: Int64
        var status = Status.waiting
        var thumbnail: CGImage?

        var name: String { url.lastPathComponent }
    }

    let queue: BatchQueue<Item>

    init(outputParent: URL? = nil) {
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Cutouts", logCategory: "remove-background", failureLog: "Background removal failed",
                                     skippedBecause: "had no images", files: BatchFiles.images), outputParent: outputParent)
    }

    var selectedID: UUID?

    var settings = RemoveBackgroundSettings()

    var hasPending: Bool { queue.hasWaiting }
    var selected: Item? { items.first { $0.id == selectedID } }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: Queue

    func add(_ urls: [URL]) {
        let fresh = queue.add(urls) { Item(url: $0, bytes: BatchFiles.bytes(of: $0)) }
        if selectedID == nil { selectedID = items.first?.id }
        for item in fresh { loadThumbnail(item.id, from: item.url) }
    }

    func remove(_ id: UUID) {
        guard queue.remove(id) else { return }
        if selectedID == id { selectedID = items.first?.id }
    }

    func clear() {
        queue.clear()
        selectedID = nil
    }

    private func loadThumbnail(_ id: UUID, from url: URL) {
        Task {
            let thumbnail = await Task.detached(priority: .utility) { ImageConverter.thumbnail(of: url, maxSize: 120) }.value
            queue.update(id) { $0.thumbnail = thumbnail }
        }
    }

    // MARK: Removing backgrounds

    func removeBackgrounds() {
        guard hasPending else { return }
        let settings = self.settings
        queue.run(retryingFailed: false) { item, folder, step in
            let result = try await step.detached(showing: .cutting) {
                try RemoveBackground.save(source: item.url, settings: settings, into: folder)
            }
            Log.info("Background removed", category: "remove-background", ["background": settings.background.rawValue])
            return .done(result)
        }
    }
}
