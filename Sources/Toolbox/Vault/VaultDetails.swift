import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VaultRenameError: LocalizedError, Equatable {
    case empty
    case badCharacter
    case startsWithDot
    case tooLong
    case taken

    static let maxNameBytes = 255

    var errorDescription: String? {
        switch self {
        case .empty: "Type a name."
        case .badCharacter: "Names can't contain / or :."
        case .startsWithDot: "Names can't start with a dot; the file would be hidden."
        case .tooLong: "That name is too long."
        case .taken: "Another file in the vault already has that name."
        }
    }
}

enum VaultRename {
    static func editableName(of item: VaultItem) -> String {
        (item.name as NSString).deletingPathExtension
    }

    static func fileName(for typed: String, renaming item: VaultItem) -> Result<String, VaultRenameError> {
        let stem = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return .failure(.empty) }
        guard !stem.contains("/"), !stem.contains(":") else { return .failure(.badCharacter) }
        guard !stem.hasPrefix(".") else { return .failure(.startsWithDot) }
        let ext = item.url.pathExtension
        let name = ext.isEmpty ? stem : "\(stem).\(ext)"
        guard name.utf8.count <= VaultRenameError.maxNameBytes else { return .failure(.tooLong) }
        return .success(name)
    }

    static func destination(for typed: String, renaming item: VaultItem) -> Result<URL?, VaultRenameError> {
        fileName(for: typed, renaming: item).flatMap { name in
            guard name != item.name else { return .success(nil) }
            let target = item.url.deletingLastPathComponent().appendingPathComponent(name)
            let onlyCaseChanges = name.lowercased() == item.name.lowercased()
            if !onlyCaseChanges && FileManager.default.fileExists(atPath: target.path) { return .failure(.taken) }
            return .success(target)
        }
    }

    static func move(_ item: VaultItem, to target: URL) throws {
        if target.lastPathComponent.lowercased() == item.name.lowercased() {
            let step = item.url.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: item.url, to: step)
            try FileManager.default.moveItem(at: step, to: target)
        } else {
            try FileManager.default.moveItem(at: item.url, to: target)
        }
    }
}

enum VaultSearchStatus: Equatable {
    case checking
    case indexed(picture: Bool, sound: Bool)
    case adding
    case notIndexed
    case failed
    case needsModel
    case off(String)
}

struct VaultFileDetails: Equatable {
    struct Line: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var lines: [Line]

    static func load(_ item: VaultItem, playable: URL) async -> VaultFileDetails {
        var lines = [Line(label: "Kind", value: kindDescription(item)),
                     Line(label: "Size", value: ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)),
                     Line(label: "Added to vault", value: item.added.formatted(date: .abbreviated, time: .shortened))]
        if let created = (try? item.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
            lines.append(Line(label: "File created", value: created.formatted(date: .abbreviated, time: .shortened)))
        }
        switch item.kind {
        case .video: lines += await videoLines(item.url, playable: playable)
        case .image: lines += imageLines(item.url)
        }
        return VaultFileDetails(lines: lines)
    }

    static func videoLines(_ url: URL, playable: URL) async -> [Line] {
        guard let report = try? await MediaInspector.inspect(url) else { return [Line(label: "Video", value: "Can't be read")] }
        var lines = [Line(label: "Length", value: VaultTime.label(report.duration))]
        if let video = report.videoTracks.first {
            lines.append(Line(label: "Resolution", value: "\(video.width) × \(video.height)"))
            if let fps = video.frameRate { lines.append(Line(label: "Frame rate", value: String(format: "%.2f fps", fps))) }
            lines.append(Line(label: "Video codec", value: video.codec))
        }
        if let bitrate = report.overallBitrate { lines.append(Line(label: "Bitrate", value: MediaFormat.bitrate(bitrate))) }
        lines.append(Line(label: "Sound", value: await soundDescription(report, original: url, playable: playable)))
        return lines
    }

    static func soundDescription(_ report: MediaReport, original: URL, playable: URL) async -> String {
        if let audio = report.audioTracks.first { return audio.codec }
        guard playable != original, let copy = try? await MediaInspector.inspect(playable), let audio = copy.audioTracks.first else {
            return "No sound"
        }
        return "\(audio.codec), played from a lossless copy"
    }

    static func imageLines(_ url: URL) -> [Line] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return [Line(label: "Image", value: "Can't be read")] }
        return [Line(label: "Dimensions", value: "\(width) × \(height)")]
    }

    private static func kindDescription(_ item: VaultItem) -> String {
        let type = UTType(filenameExtension: item.url.pathExtension.lowercased())
        return type?.localizedDescription ?? item.url.pathExtension.uppercased()
    }
}
