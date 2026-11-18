import AppKit
import Observation

@MainActor @Observable
final class MuteVideoModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = MuteVideoModel()

    enum Status: BatchStatus {
        case waiting
        case muting(Double)
        case done(MuteResult)
        case silent
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
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Muted Videos", logCategory: "mute", failureLog: "Mute failed",
                                     skippedBecause: "had no videos", files: BatchFiles.videos), outputParent: outputParent)
    }

    var hasPending: Bool { queue.hasWaiting }
    var results: [MuteResult] { items.compactMap { if case .done(let r) = $0.status { r } else { nil } } }
    var savedBytes: Int64 { results.reduce(0) { $0 + $1.savedBytes } }

    func add(_ urls: [URL]) { queue.add(urls) { Item(url: $0) } }

    func mute() {
        queue.run { item, folder, step in
            switch try await VideoMuter.mute(source: item.url, into: folder, progress: step.progress { .muting($0) }) {
            case .muted(let result):
                Log.info("Video muted", category: "mute", ["reencoded": String(result.reencoded)])
                return .done(result)
            case .alreadySilent:
                return .silent
            }
        }
    }
}
