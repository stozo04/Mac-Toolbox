import AVFoundation
import Foundation

enum VaultPlayableError: LocalizedError {
    case soundHiddenFromAVFoundation(codec: String)
    case remuxFailed(String)

    var errorDescription: String? {
        switch self {
        case .soundHiddenFromAVFoundation(let codec): "AVFoundation sees no sound track, but the file has \(codec) sound"
        case .remuxFailed(let reason): "Making a playable copy failed: \(reason)"
        }
    }
}

/// Some videos (HEVC with MP3 sound in an .mp4) have sound that AVFoundation can't see, so they play silently
/// and their sound can't be searched. For those, a lossless .mov copy (streams copied, not re-encoded) is kept
/// in the vault's private folder, inside the encrypted image. The vault file itself is never changed.
enum VaultPlayable {
    static let folderName = "playable"
    static let copyExtension = "mov"
    private static let partialPrefix = ".partial-"

    static func folder(in privateFolder: URL) -> URL { privateFolder.appendingPathComponent(folderName) }

    static func copyURL(for item: VaultItem, privateFolder: URL) -> URL {
        folder(in: privateFolder).appendingPathComponent(VaultThumbnails.key(for: item)).appendingPathExtension(copyExtension)
    }

    /// The file to play and to read sound from: the playable copy when the original's sound is hidden from
    /// AVFoundation, otherwise the original.
    static func url(for item: VaultItem, privateFolder: URL, tools: MediaTools? = MediaTools.find()) async -> URL {
        guard item.kind == .video else { return item.url }
        let copy = copyURL(for: item, privateFolder: privateFolder)
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        guard await !avFoundationHearsSound(item.url) else { return item.url }
        guard let tools, let codec = await hasSoundStream(item.url, tools: tools) else { return item.url }
        Log.warning("Vault video sound hidden from AVFoundation", category: VaultLog.category,
                    VaultLog.details(VaultPlayableError.soundHiddenFromAVFoundation(codec: codec), file: item.url))
        do {
            try await makeCopy(of: item.url, to: copy, tools: tools)
            return copy
        } catch {
            VaultLog.failure("Vault playable copy failed", error, file: item.url)
            return item.url
        }
    }

    static func needsCopy(_ item: VaultItem, privateFolder: URL, tools: MediaTools?) async -> Bool {
        guard item.kind == .video, let tools,
              !FileManager.default.fileExists(atPath: copyURL(for: item, privateFolder: privateFolder).path),
              await !avFoundationHearsSound(item.url) else { return false }
        return await hasSoundStream(item.url, tools: tools) != nil
    }

    static func avFoundationHearsSound(_ url: URL) async -> Bool {
        let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
    }

    /// The codec of the first sound stream ffprobe finds, or nil when there is none.
    static func hasSoundStream(_ url: URL, tools: MediaTools?) async -> String? {
        guard let tools,
              let result = try? await Shell.run(tools.ffprobe.path, probeArguments(url)), result.succeeded else { return nil }
        return firstCodec(inProbeOutput: result.out)
    }

    static func probeArguments(_ url: URL) -> [String] {
        ["-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path]
    }

    static func firstCodec(inProbeOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            .first { !$0.isEmpty }
    }

    static func remuxArguments(from source: URL, to destination: URL) -> [String] {
        ["-nostdin", "-v", "error", "-y", "-i", source.path, "-map", "0:v:0", "-map", "0:a?", "-c", "copy",
         "-f", "mov", destination.path]
    }

    static func makeCopy(of source: URL, to destination: URL, tools: MediaTools) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(partialPrefix + UUID().uuidString).appendingPathExtension(copyExtension)
        defer { try? FileManager.default.removeItem(at: partial) }
        let result = try await Shell.run(tools.ffmpeg.path, remuxArguments(from: source, to: partial))
        guard result.succeeded else { throw VaultPlayableError.remuxFailed(String(result.err.suffix(300))) }
        guard await avFoundationHearsSound(partial) else {
            throw VaultPlayableError.remuxFailed("the copy's sound still can't be read")
        }
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    static func remove(_ items: [VaultItem], privateFolder: URL) {
        for item in items { try? FileManager.default.removeItem(at: copyURL(for: item, privateFolder: privateFolder)) }
    }

    static func prune(keeping items: [VaultItem], privateFolder: URL) {
        let wanted = Set(items.filter { $0.kind == .video }.map { copyURL(for: $0, privateFolder: privateFolder).lastPathComponent })
        let folder = folder(in: privateFolder)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where !wanted.contains(name) && !name.hasPrefix(partialPrefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
