import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class VideoToGifModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = VideoToGifModel()

    enum Status: BatchStatus {
        case waiting
        case converting(Double)
        case done(URL, bytes: Int64)
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
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox GIFs", logCategory: "gif", failureLog: "GIF failed",
                                     skippedBecause: "had no videos", files: BatchFiles.videos), outputParent: outputParent)
    }

    var fps = 15
    var maxWidth: Int? = 480
    var loopForever = true
    var partOnly = false
    var startText = "0:00.00"
    var lengthText = "0:05.00"

    var hasPending: Bool { queue.hasWaiting }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }

    /// Nil when the part fields can't be read; the UI shows why.
    var settings: GifSettings? {
        var s = GifSettings(fps: fps, maxWidth: maxWidth, loopForever: loopForever)
        if partOnly {
            guard let start = TrimTime.parse(startText), let length = TrimTime.parse(lengthText), length > 0 else { return nil }
            s.part = (start, length)
        }
        return s
    }

    func add(_ urls: [URL]) { queue.add(urls) { Item(url: $0) } }

    func removeFinished() {
        queue.remove { if case .done = $0.status { true } else { false } }
    }

    // MARK: Converting

    func convert() {
        guard hasPending, let settings else { return }
        queue.run { item, folder, step in
            let gif = try await GifConverter.convert(source: item.url, settings: settings, into: folder, progress: step.progress { .converting($0) })
            let bytes = (try? gif.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            Log.info("GIF finished", category: "gif", ["fps": String(settings.fps), "part": String(settings.part != nil)])
            return .done(gif, bytes: bytes)
        }
    }
}
