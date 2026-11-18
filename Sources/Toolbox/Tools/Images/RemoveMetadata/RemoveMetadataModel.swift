import AppKit
import ImageIO
import Observation

@MainActor @Observable
final class RemoveMetadataModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = RemoveMetadataModel()

    enum Status: BatchStatus {
        case waiting
        case working
        case done(StripResult)
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Item: BatchItem {
        let id = UUID()
        let url: URL
        let bytes: Int64
        /// What the photo carries now, read when it was added.
        let found: Set<MetadataKind>
        var status = Status.waiting

        /// "HEIC", "JPEG"... from the file's extension.
        var kind: String { ImageFormat.name(forExtension: url.pathExtension) }
    }

    let queue: BatchQueue<Item>

    init(outputParent: URL? = nil) {
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Clean Photos", logCategory: "remove-metadata", failureLog: "Metadata removal failed",
                                     skippedBecause: "had no photos", files: BatchFiles.images), outputParent: outputParent)
    }

    var settings = StripSettings()

    var hasPending: Bool { queue.hasWaiting }

    private var results: [StripResult] {
        items.compactMap { if case .done(let r) = $0.status { r } else { nil } }
    }
    var doneCount: Int { results.count }
    /// How many finished photos actually had something taken out.
    var cleanedCount: Int { results.filter { !$0.removed.isEmpty }.count }
    /// The kinds of details found in the photos waiting to be cleaned.
    var pendingKinds: Set<MetadataKind> {
        items.filter { $0.status == .waiting }.reduce(into: []) { $0.formUnion($1.found) }
    }

    func add(_ urls: [URL]) {
        queue.add(urls) { url in
            let reader = CGImageSourceCreateWithURL(url as CFURL, nil)
            return Item(url: url, bytes: BatchFiles.bytes(of: url), found: reader.map { MetadataStripper.scan($0) } ?? [])
        }
    }

    // MARK: Cleaning

    func removeMetadata() {
        guard hasPending else { return }
        let settings = self.settings
        queue.run { item, folder, step in
            let result = try await step.detached(showing: .working) {
                try MetadataStripper.strip(source: item.url, settings: settings, into: folder)
            }
            Log.info("Metadata removed", category: "remove-metadata", ["kind": item.kind, "keepOrientation": "\(settings.keepOrientation)"])
            return .done(result)
        }
    }
}
