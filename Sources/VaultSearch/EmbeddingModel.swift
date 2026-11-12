import CryptoKit
import Foundation

public enum EmbeddingModel {
    public static let name = "EmbeddingGemma 2"
    public static let repository = "ggml-org/embeddinggemma-2-GGUF"
    public static let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"

    public struct File: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let sha256: String

        public var url: URL {
            URL(string: "https://huggingface.co/\(EmbeddingModel.repository)/resolve/\(EmbeddingModel.revision)/\(name)")!
        }
    }

    public static let text = File(name: "embeddinggemma-2-Q8_0.gguf", bytes: 309_855_456,
                                  sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135")
    public static let media = File(name: "mmproj-embeddinggemma-2-Q8_0.gguf", bytes: 554_821_024,
                                   sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
    public static let all = [text, media]
    public static let totalBytes = all.reduce(0) { $0 + $1.bytes }

    public struct Located: Sendable, Equatable {
        public let text: URL
        public let media: URL

        public init(text: URL, media: URL) {
            self.text = text
            self.media = media
        }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var toolboxFolder: URL {
        home.appendingPathComponent("Library/Application Support/Toolbox/AI Models/EmbeddingGemma 2")
    }

    public static var digUpFolder: URL { home.appendingPathComponent("Library/Application Support/DigUp/Models") }

    public static var huggingFaceSnapshot: URL {
        let environment = ProcessInfo.processInfo.environment
        let hub = environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? environment["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") }
            ?? home.appendingPathComponent(".cache/huggingface/hub")
        return hub.appendingPathComponent("models--\(repository.replacingOccurrences(of: "/", with: "--"))/snapshots/\(revision)")
    }

    public static var searchFolders: [URL] { [toolboxFolder, digUpFolder, huggingFaceSnapshot] }

    public static func locate(in folders: [URL] = searchFolders) -> Located? {
        for folder in folders {
            let textURL = folder.appendingPathComponent(text.name)
            let mediaURL = folder.appendingPathComponent(media.name)
            if hasRightSize(textURL, text), hasRightSize(mediaURL, media) {
                return Located(text: textURL.resolvingSymlinksInPath(), media: mediaURL.resolvingSymlinksInPath())
            }
        }
        return nil
    }

    public static func hasRightSize(_ url: URL, _ file: File) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.size] as? NSNumber)?.int64Value
        return size == file.bytes
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done = try autoreleasepool { () -> Bool in
                guard let data = try handle.read(upToCount: 8 << 20), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
