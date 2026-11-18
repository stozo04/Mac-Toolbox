import AppKit
import Observation

@MainActor @Observable
final class ResizeVideoModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = ResizeVideoModel()

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
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Videos", logCategory: "resize", failureLog: "Resize failed",
                                     skippedBecause: "had no videos", files: BatchFiles.videos), outputParent: outputParent)
    }

    var preset = SizePreset.all[2] {
        didSet {
            guard let size = preset.size else { return }
            editingBoth = true
            width = Int(size.width)
            height = Int(size.height)
            editingBoth = false
        }
    }
    var width = 1920 { didSet { if width != oldValue && !editingBoth { syncPreset() } } }
    var height = 1080 { didSet { if height != oldValue && !editingBoth { syncPreset() } } }
    var keepAspect = true
    var fit = ResizeFit.blackBars
    var codec = ResizeCodec.h264

    /// Set while width and height change together, so a half-finished change can't match a preset.
    private var editingBoth = false

    var hasPending: Bool { queue.hasWaiting }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }
    var settings: ResizeSettings { ResizeSettings(width: width, height: height, keepAspect: keepAspect, fit: fit, codec: codec) }
    var isValidSize: Bool { (2...16384).contains(width) && (2...16384).contains(height) }
    var evenNote: Bool { width % 2 != 0 || height % 2 != 0 }

    func swapSize() {
        editingBoth = true
        (width, height) = (height, width)
        editingBoth = false
        syncPreset()
    }

    /// Typing a size that matches a preset selects it; anything else is Custom.
    private func syncPreset() {
        let match = SizePreset.all.first { $0.size == CGSize(width: width, height: height) } ?? .custom
        if match != preset { preset = match }
    }

    func add(_ urls: [URL]) { queue.add(urls) { Item(url: $0) } }

    // MARK: Resizing

    func resize() {
        guard hasPending, isValidSize else { return }
        let settings = self.settings
        queue.run { item, folder, step in
            let out = try await VideoResizer.resize(source: item.url, settings: settings, into: folder, progress: step.progress { .converting($0) })
            let bytes = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            Log.info("Resize finished", category: "resize", ["codec": settings.codec.rawValue, "fit": settings.keepAspect ? settings.fit.rawValue : "stretch"])
            return .done(out, bytes: bytes)
        }
    }
}
