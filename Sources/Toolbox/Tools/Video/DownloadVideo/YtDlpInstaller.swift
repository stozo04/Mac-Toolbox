import Foundation
import VaultSearch

enum YtDlpInstallError: LocalizedError, Equatable {
    case badResponse(file: String, status: Int)
    case checksumNotListed(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let file, let status): "Could not download \(file) from GitHub (the server answered \(status))."
        case .checksumNotListed(let file): "The yt-dlp release lists no checksum for \(file), so it was not installed."
        case .checksumMismatch(let file): "\(file) didn't match its checksum, so it was not installed."
        }
    }
}

/// The checksum comes from the same release as the program: it catches a damaged, cut-off or swapped download, not a release that was itself tampered with.
struct YtDlpInstaller {
    static let assetName = "yt-dlp_macos"
    static let checksumsName = "SHA2-256SUMS"
    private static let executable: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
    private static let latestRelease = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"

    var session: URLSession = .shared
    var programURL = URL(string: latestRelease + assetName)
    var checksumsURL = URL(string: latestRelease + checksumsName)
    var destination = YtDlpLocator.installedURL

    func install() async throws {
        guard let programURL, let checksumsURL else { throw URLError(.badURL) }
        let downloaded = try await download(programURL, named: Self.assetName)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let checksums = try await download(checksumsURL, named: Self.checksumsName)
        defer { try? FileManager.default.removeItem(at: checksums) }
        guard let expected = Self.sha256(for: Self.assetName, inChecksums: try String(contentsOf: checksums, encoding: .utf8)) else {
            throw YtDlpInstallError.checksumNotListed(Self.assetName)
        }
        guard try await Task.detached(operation: { try EmbeddingModel.sha256(of: downloaded) }).value == expected else {
            throw YtDlpInstallError.checksumMismatch(Self.assetName)
        }
        try swapIn(downloaded)
    }

    /// `sha256sum` stars the name of a file it hashed in binary mode.
    static func sha256(for asset: String, inChecksums listing: String) -> String? {
        listing.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, let hash = fields.first, let name = fields.last,
                  name == asset || name == "*" + asset else { return nil }
            return hash.lowercased()
        }.first
    }

    private func download(_ url: URL, named name: String) async throws -> URL {
        let (file, response) = try await session.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw YtDlpInstallError.badResponse(file: name, status: status ?? 0)
        }
        return file
    }

    private func swapIn(_ program: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try fm.moveItem(at: program, to: staged)
        try fm.setAttributes(Self.executable, ofItemAtPath: staged.path)
        _ = try fm.replaceItemAt(destination, withItemAt: staged)
        // The swap can keep the permissions of the file it replaced.
        try fm.setAttributes(Self.executable, ofItemAtPath: destination.path)
    }
}
