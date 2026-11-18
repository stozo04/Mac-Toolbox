import AppKit
import Observation

@MainActor @Observable
final class CompressVideoModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = CompressVideoModel()

    enum Status: BatchStatus {
        case waiting
        case compressing(Double)
        case done(VideoCompressResult)
        case notSmaller(originalBytes: Int64)
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Item: BatchItem {
        let id = UUID()
        let url: URL
        var status = Status.waiting
    }

    let queue: BatchQueue<Item>

    init(outputParent: URL? = nil) {
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Compressed Videos", logCategory: "compress", failureLog: "Compress failed",
                                     skippedBecause: "had no videos", files: BatchFiles.videos), outputParent: outputParent)
    }

    var settings = VideoCompressSettings()

    var hasPending: Bool { queue.hasWaiting }
    var results: [VideoCompressResult] { items.compactMap { if case .done(let r) = $0.status { r } else { nil } } }
    var savedBytes: Int64 { results.reduce(0) { $0 + $1.savedBytes } }
    var originalBytes: Int64 { results.reduce(0) { $0 + $1.originalBytes } }
    /// Files that could not be made smaller; nothing was written for them.
    var keptCount: Int { items.filter { if case .notSmaller = $0.status { true } else { false } }.count }

    func add(_ urls: [URL]) { queue.add(urls) { Item(url: $0) } }

    // MARK: Compressing

    func compress() {
        guard hasPending else { return }
        let settings = self.settings
        let choices = ["quality": settings.quality.rawValue, "codec": settings.codec.rawValue,
                       "maxSize": settings.maxSize.rawValue, "hardware": String(settings.hardwareEncoder)]
        let failureContext = choices.merging(["removeAudio": String(settings.removeAudio)]) { $1 }
        queue.run(failureContext: failureContext) { item, folder, step in
            switch try await VideoCompressor.compress(source: item.url, settings: settings, into: folder, progress: step.progress { .compressing($0) }) {
            case .compressed(let result):
                Log.info("Video compressed", category: "compress",
                         choices.merging(["savedPercent": String(Int((result.savedFraction * 100).rounded()))]) { $1 })
                return .done(result)
            case .notSmaller(let original, _):
                return .notSmaller(originalBytes: original)
            }
        }
    }
}
