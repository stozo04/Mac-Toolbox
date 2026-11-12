import Foundation

enum VaultLog {
    static let category = "vault"
    static let hiddenName = "<vault file>"

    static func failure(_ message: String, _ error: Error, file: URL? = nil, _ context: [String: String] = [:]) {
        Log.error(message, category: category, details(error, file: file, context))
    }

    static func details(_ error: Error, file: URL?, _ context: [String: String] = [:]) -> [String: String] {
        var metadata = Log.details(error, file: nil, context)
        if let file {
            metadata = metadata.mapValues { hideName(of: file, in: $0) }
            if !file.pathExtension.isEmpty { metadata["file_ext"] = file.pathExtension.lowercased() }
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { metadata["file_bytes"] = String(size) }
        }
        return metadata
    }

    static func hideName(of file: URL, in text: String) -> String {
        let name = file.lastPathComponent
        let stem = file.deletingPathExtension().lastPathComponent
        return [file.path, name, stem].filter { !$0.isEmpty }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: hiddenName) }
    }
}
