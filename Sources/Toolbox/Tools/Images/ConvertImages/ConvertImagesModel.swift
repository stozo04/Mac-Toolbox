import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class ConvertImagesModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = ConvertImagesModel()

    enum Status: BatchStatus {
        case waiting
        case converting
        case done(ConvertResult)
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
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Converted Images", logCategory: "convert-images", failureLog: "Image conversion failed",
                                     skippedBecause: "had no images", files: BatchFiles.images), outputParent: outputParent)
    }

    var settings = ConvertSettings()

    var hasPending: Bool { queue.hasWaiting }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }

    func add(_ urls: [URL]) { queue.add(urls) { Item(url: $0, bytes: BatchFiles.bytes(of: $0)) } }

    // MARK: Converting

    func convert() {
        guard hasPending else { return }
        let settings = self.settings
        queue.run(failureContext: ["to": settings.format.ext]) { item, folder, step in
            let result = try await step.detached(showing: .converting) {
                try ImageConverter.convert(source: item.url, settings: settings, into: folder)
            }
            Log.info("Image converted", category: "convert-images", ["from": item.kind, "to": settings.format.ext])
            return .done(result)
        }
    }
}
