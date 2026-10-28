import AVFoundation

enum AssetExportError: LocalizedError {
    case unsupported
    case failed

    var errorDescription: String? {
        switch self {
        case .unsupported: "This video can't be saved in that format."
        case .failed: "The video could not be saved."
        }
    }
}

/// Runs an `AVAssetExportSession` as an async call with progress and cancellation.
/// A cancelled or failed export leaves no partial file behind.
enum AssetExporter {
    private final class Session: @unchecked Sendable {
        let value: AVAssetExportSession
        init(_ value: AVAssetExportSession) { self.value = value }
    }

    static func export(_ asset: AVAsset, preset: String, type: AVFileType, metadata: [AVMetadataItem] = [],
                       videoComposition: AVVideoComposition? = nil, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let made = AVAssetExportSession(asset: asset, presetName: preset),
              made.supportedFileTypes.contains(type) else { throw AssetExportError.unsupported }
        let session = Session(made)
        session.value.outputURL = url
        session.value.outputFileType = type
        if !metadata.isEmpty { session.value.metadata = metadata }
        if let videoComposition { session.value.videoComposition = videoComposition }

        try await withTaskCancellationHandler {
            let poll = Task {
                while !Task.isCancelled {
                    progress(Double(session.value.progress))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                session.value.exportAsynchronously { done.resume() }
            }
            poll.cancel()
            switch session.value.status {
            case .completed: progress(1)
            case .cancelled:
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            default:
                try? FileManager.default.removeItem(at: url)
                throw session.value.error ?? AssetExportError.failed
            }
        } onCancel: {
            session.value.cancelExport()
        }
    }
}
