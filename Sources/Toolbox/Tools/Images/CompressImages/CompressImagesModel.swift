import AppKit
import Observation

@MainActor @Observable
final class CompressImagesModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = CompressImagesModel()

    enum Status: BatchStatus {
        case waiting
        case compressing
        case done(CompressResult)
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Item: BatchItem {
        let id = UUID()
        let url: URL
        let bytes: Int64
        var status = Status.waiting

        /// "HEIC", "JPEG"... from the file's extension.
        var kind: String { ImageFormat.name(forExtension: url.pathExtension) }
    }

    let queue: BatchQueue<Item>

    init(outputParent: URL? = nil) {
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Compressed Images", logCategory: "compress-images", failureLog: "Image compression failed",
                                     skippedBecause: "had no images", files: BatchFiles.images), outputParent: outputParent)
    }

    var settings = CompressSettings()

    var hasPending: Bool { queue.hasWaiting }

    private var results: [CompressResult] {
        items.compactMap { if case .done(let r) = $0.status { r } else { nil } }
    }
    var doneCount: Int { results.count }
    /// Bytes saved over all finished files, and what those files weighed before.
    var savedBytes: Int64 { results.reduce(0) { $0 + $1.savedBytes } }
    var originalBytes: Int64 { results.reduce(0) { $0 + $1.sourceBytes } }

    func add(_ urls: [URL]) { queue.add(urls) { Item(url: $0, bytes: BatchFiles.bytes(of: $0)) } }

    // MARK: Compressing

    func compress() {
        guard hasPending else { return }
        let settings = self.settings
        queue.run { item, folder, step in
            let result = try await step.detached(showing: .compressing) {
                try ImageCompressor.compress(source: item.url, settings: settings, into: folder)
            }
            Log.info("Image compressed", category: "compress-images", ["kind": item.kind, "level": settings.level.rawValue, "format": settings.format.rawValue])
            return .done(result)
        }
    }
}
