import Foundation
import VaultSearch

enum VaultModelDownloadError: LocalizedError {
    case badResponse(Int)
    case checksum(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status): "The download server answered \(status)."
        case .checksum(let name): "\(name) didn't match its checksum, so it was thrown away."
        }
    }
}

enum VaultModelDownload {
    static func run(into folder: URL = EmbeddingModel.toolboxFolder, progress: @escaping @Sendable (Double) -> Void) async throws -> EmbeddingModel.Located {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = Double(EmbeddingModel.totalBytes)
        var finishedBytes = 0.0
        for file in EmbeddingModel.all {
            let destination = folder.appendingPathComponent(file.name)
            if EmbeddingModel.hasRightSize(destination, file) {
                finishedBytes += Double(file.bytes)
                progress(finishedBytes / total)
                continue
            }
            let before = finishedBytes
            let delegate = DownloadProgress { written in progress((before + Double(written)) / total) }
            let (temporary, response) = try await URLSession.shared.download(from: file.url, delegate: delegate)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temporary)
                throw VaultModelDownloadError.badResponse(http.statusCode)
            }
            let digest = try await Task.detached { try EmbeddingModel.sha256(of: temporary) }.value
            guard digest == file.sha256 else {
                try? FileManager.default.removeItem(at: temporary)
                throw VaultModelDownloadError.checksum(file.name)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            finishedBytes += Double(file.bytes)
            progress(finishedBytes / total)
        }
        guard let located = EmbeddingModel.locate(in: [folder]) else { throw VaultModelDownloadError.checksum(EmbeddingModel.name) }
        return located
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: (Int64) -> Void

    init(report: @escaping (Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
