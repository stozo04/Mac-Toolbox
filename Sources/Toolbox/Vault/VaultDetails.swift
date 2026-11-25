import Foundation
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
        let quality = await VaultQuality.read(item, inVault: true, playable: playable)
        let kind = Line(label: "Kind", value: kindDescription(item))
        return VaultFileDetails(lines: [kind] + quality.lines.map { Line(label: $0.label, value: $0.value) })
    }

    private static func kindDescription(_ item: VaultItem) -> String {
        let type = UTType(filenameExtension: item.url.pathExtension.lowercased())
        return type?.localizedDescription ?? item.url.pathExtension.uppercased()
    }
}
