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
///
/// What was found is remembered per file (its path and size), so a video is only probed once:
/// `<key>.mov` is the playable copy, `<key>.checked` means no copy is needed, `<key>.failed` means making one failed.
enum VaultPlayable {
    static let folderName = "playable"
    static let copyExtension = "mov"
    static let checkedExtension = "checked"
    static let failedExtension = "failed"
    static let soundReadExtension = "sound-read"
    private static let partialPrefix = ".partial-"
    private static let stderrKept = 300

    enum Outcome: Equatable {
        case original
        case copy(URL)
    }

    static func folder(in privateFolder: URL) -> URL { privateFolder.appendingPathComponent(folderName) }

    static func copyURL(for item: VaultItem, privateFolder: URL) -> URL {
        record(for: item, privateFolder: privateFolder, extension: copyExtension)
    }

    private static func record(for item: VaultItem, privateFolder: URL, extension ext: String) -> URL {
        folder(in: privateFolder).appendingPathComponent(VaultThumbnails.key(for: item)).appendingPathExtension(ext)
    }

    /// The file to play and to read sound from: the playable copy when the original's sound is hidden from
    /// AVFoundation, otherwise the original.
    static func url(for item: VaultItem, privateFolder: URL, tools: MediaTools? = MediaTools.find()) async -> URL {
        switch await resolve(item, privateFolder: privateFolder, tools: tools) {
        case .copy(let copy): copy
        case .original: item.url
        }
    }

    static func resolve(_ item: VaultItem, privateFolder: URL, tools: MediaTools?) async -> Outcome {
        guard item.kind == .video else { return .original }
        let copy = copyURL(for: item, privateFolder: privateFolder)
        if FileManager.default.fileExists(atPath: copy.path) { return .copy(copy) }
        guard !isSettled(item, privateFolder: privateFolder), let tools else { return .original }
        guard let hears = await avFoundationHearsSound(item.url) else { return unanswered(item, privateFolder: privateFolder) }
        if hears {
            mark(item, privateFolder: privateFolder, as: checkedExtension)
            return .original
        }
        guard let probe = await soundStream(item.url, tools: tools) else { return unanswered(item, privateFolder: privateFolder) }
        guard let codec = probe else {
            mark(item, privateFolder: privateFolder, as: checkedExtension)
            return .original
        }
        Log.info("Vault video sound hidden from AVFoundation", category: VaultLog.category,
                 VaultLog.details(VaultPlayableError.soundHiddenFromAVFoundation(codec: codec), file: item.url))
        do {
            try await makeCopy(of: item.url, to: copy, tools: tools)
            return .copy(copy)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return .original }
            mark(item, privateFolder: privateFolder, as: failedExtension)
            VaultLog.failure("Vault playable copy failed", error, file: item.url)
            return .original
        }
    }

    /// A check that couldn't answer: nothing is remembered when it was cancelled, otherwise it counts as failed
    /// so the file isn't probed (and re-indexed) on every pass.
    private static func unanswered(_ item: VaultItem, privateFolder: URL) -> Outcome {
        if !Task.isCancelled { mark(item, privateFolder: privateFolder, as: failedExtension) }
        return .original
    }

    /// True when this video has not been looked at yet. Search uses it to read a video's sound again once.
    static func needsLook(_ item: VaultItem, privateFolder: URL) -> Bool {
        item.kind == .video && !isSettled(item, privateFolder: privateFolder)
            && !FileManager.default.fileExists(atPath: copyURL(for: item, privateFolder: privateFolder).path)
    }

    /// True when search should read this video's sound again: it hasn't been looked at, or it has a playable copy
    /// (made by the viewer, say) whose sound search hasn't read yet.
    static func needsSoundRead(_ item: VaultItem, privateFolder: URL) -> Bool {
        guard item.kind == .video else { return false }
        if FileManager.default.fileExists(atPath: copyURL(for: item, privateFolder: privateFolder).path) {
            return !FileManager.default.fileExists(atPath: record(for: item, privateFolder: privateFolder, extension: soundReadExtension).path)
        }
        return needsLook(item, privateFolder: privateFolder)
    }

    /// Reads a video's sound for search, from its playable copy when it has one. A read from the copy is recorded
    /// whether it worked or not (only cancelling is not), so search tries a copy once instead of on every pass.
    static func readSound<Piece>(of item: VaultItem, privateFolder: URL, tools: MediaTools? = MediaTools.find(),
                                 read: (URL) async throws -> [Piece]) async throws -> [Piece] {
        let source = await url(for: item, privateFolder: privateFolder, tools: tools)
        guard source != item.url else { return try await read(source) }
        do {
            let pieces = try await read(source)
            mark(item, privateFolder: privateFolder, as: soundReadExtension)
            return pieces
        } catch {
            if !(error is CancellationError), !Task.isCancelled {
                mark(item, privateFolder: privateFolder, as: soundReadExtension)
            }
            throw error
        }
    }

    private static func isSettled(_ item: VaultItem, privateFolder: URL) -> Bool {
        [checkedExtension, failedExtension].contains {
            FileManager.default.fileExists(atPath: record(for: item, privateFolder: privateFolder, extension: $0).path)
        }
    }

    private static func mark(_ item: VaultItem, privateFolder: URL, as ext: String) {
        let file = record(for: item, privateFolder: privateFolder, extension: ext)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())
    }

    /// nil when AVFoundation could not answer (the file didn't load, or the task was cancelled).
    static func avFoundationHearsSound(_ url: URL) async -> Bool? {
        guard let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio), !Task.isCancelled else { return nil }
        return !tracks.isEmpty
    }

    /// `.some(codec)` for the first sound stream ffprobe finds, `.some(nil)` when there is none, nil when ffprobe failed.
    static func soundStream(_ url: URL, tools: MediaTools) async -> String?? {
        guard !Task.isCancelled,
              let result = try? await Shell.run(tools.ffprobe.path, probeArguments(url)), result.succeeded else { return nil }
        return .some(firstCodec(inProbeOutput: result.out))
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
        try Task.checkCancellation()
        guard result.succeeded else {
            let scrubbed = VaultLog.hideName(of: source, in: VaultLog.hideName(of: partial, in: result.err))
            throw VaultPlayableError.remuxFailed(String(scrubbed.suffix(stderrKept)))
        }
        guard await avFoundationHearsSound(partial) == true else {
            try Task.checkCancellation()
            throw VaultPlayableError.remuxFailed("the copy's sound still can't be read")
        }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch where FileManager.default.fileExists(atPath: destination.path) {
            return
        }
    }

    static func remove(_ items: [VaultItem], privateFolder: URL) {
        for item in items {
            for ext in [copyExtension, checkedExtension, failedExtension, soundReadExtension] {
                try? FileManager.default.removeItem(at: record(for: item, privateFolder: privateFolder, extension: ext))
            }
        }
    }

    /// Drops copies and records of videos that are gone. Unfinished copies are left alone: one may be in progress.
    static func prune(keeping items: [VaultItem], privateFolder: URL) {
        let wanted = Set(items.filter { $0.kind == .video }.map { VaultThumbnails.key(for: $0) })
        let folder = folder(in: privateFolder)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where !name.hasPrefix(partialPrefix) && !wanted.contains((name as NSString).deletingPathExtension) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Unfinished copies left by a crash or a forced lock. Only call when no copy can be in progress (the vault just opened).
    static func removeUnfinishedCopies(privateFolder: URL) {
        let folder = folder(in: privateFolder)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(partialPrefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
