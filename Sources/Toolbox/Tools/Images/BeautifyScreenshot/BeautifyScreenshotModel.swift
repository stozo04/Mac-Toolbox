import AppKit
import Observation

@MainActor @Observable
final class BeautifyScreenshotModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = BeautifyScreenshotModel()

    enum Status: BatchStatus {
        /// Reading the screenshot's size; it can't be previewed yet.
        case loading
        case waiting
        case framing
        case done(BeautifyResult)
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Item: BatchItem {
        let id = UUID()
        let url: URL
        let bytes: Int64
        var status = Status.loading
        var pixelSize = CGSize.zero
        var thumbnail: CGImage?

        var name: String { url.lastPathComponent }
    }

    let queue: BatchQueue<Item>

    init(outputParent: URL? = nil) {
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Beautified Screenshots", logCategory: "beautify-screenshot", failureLog: "Screenshot framing failed",
                                     skippedBecause: "had no images", files: BatchFiles.images), outputParent: outputParent)
    }

    var selectedID: UUID?

    var settings = BeautifySettings()

    private var loader: Task<Void, Never>?

    var hasPending: Bool { queue.hasWaiting }
    var isLoading: Bool { items.contains { $0.status == .loading } }
    var selected: Item? { items.first { $0.id == selectedID } }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: Queue

    func add(_ urls: [URL]) {
        queue.add(urls) { Item(url: $0, bytes: BatchFiles.bytes(of: $0)) }
        if selectedID == nil { selectedID = items.first?.id }
        readItems()
    }

    func remove(_ id: UUID) {
        guard queue.remove(id) else { return }
        if selectedID == id { selectedID = items.first?.id }
    }

    func clear() {
        queue.clear()
        selectedID = nil
    }

    // MARK: Reading

    /// Reads the size and a thumbnail of each new screenshot, in the background.
    private func readItems() {
        guard loader == nil else { return }
        loader = Task {
            while let item = items.first(where: { $0.status == .loading }) {
                let url = item.url
                let info = await Task.detached(priority: .userInitiated) { BeautifyScreenshot.inspect(url) }.value
                queue.update(item.id) {
                    $0.pixelSize = info.size
                    $0.thumbnail = info.thumbnail
                    $0.status = .waiting
                }
            }
            loader = nil
        }
    }

    // MARK: Framing

    func beautify() {
        guard hasPending, !isLoading else { return }
        let settings = self.settings
        queue.run(retryingFailed: false) { item, folder, step in
            let result = try await step.detached(showing: .framing) {
                try BeautifyScreenshot.save(source: item.url, settings: settings, into: folder)
            }
            Log.info("Screenshot framed", category: "beautify-screenshot", ["background": settings.background.rawValue, "ratio": settings.ratio.rawValue])
            return .done(result)
        }
    }
}
