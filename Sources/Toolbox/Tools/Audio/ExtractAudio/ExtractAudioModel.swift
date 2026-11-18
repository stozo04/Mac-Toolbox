import AppKit
import Observation

@MainActor @Observable
final class ExtractAudioModel: BatchQueueModel {
    static let shared = ExtractAudioModel()
    static let outputFolderName = "Toolbox Extracted Audio"

    enum Status: BatchStatus {
        case waiting
        case extracting(Double)
        case done(ExtractAudioResult)
        case noSoundtrack
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Item: BatchItem {
        let id = UUID()
        let url: URL
        var status = Status.waiting
    }

    var settings = ExtractAudioSettings()
    let queue: BatchQueue<Item>

    init(outputParent: URL? = nil) {
        queue = BatchQueue(BatchTool(outputFolderName: Self.outputFolderName, logCategory: "extractAudio", failureLog: "Extract audio failed",
                                     skippedBecause: "had no videos", files: BatchFiles.videos), outputParent: outputParent)
    }

    var hasPending: Bool { items.contains { $0.status == .waiting || $0.isFailed } }
    var results: [ExtractAudioResult] { items.compactMap { if case .done(let r) = $0.status { r } else { nil } } }

    func add(_ urls: [URL]) { queue.add(urls) { Item(url: $0) } }

    // MARK: Extracting

    func extract() {
        let settings = self.settings
        let choices = ["format": settings.format.rawValue, "bitrate": String(settings.bitrate.rawValue)]
        queue.run(failureContext: choices) { item, folder, step in
            switch try await AudioExtractor.extract(source: item.url, into: folder, settings: settings, progress: step.progress { .extracting($0) }) {
            case .extracted(let result):
                Log.info("Audio extracted", category: "extractAudio", choices.merging(["copiedAsIs": String(result.copiedAsIs)]) { $1 })
                return .done(result)
            case .noSoundtrack:
                return .noSoundtrack
            }
        }
    }
}
