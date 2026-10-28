import Foundation

/// The few facts a GGUF model file states about itself in its header.
struct GGUFInfo: Equatable {
    var architecture: String?
    var name: String?
    var sizeLabel: String?
    /// "model", "adapter", "imatrix"...
    var type: String?
    /// The version the model's maker gave it (`general.version`), when it says.
    var version: String?
    /// Version of the GGUF format the file is written in (2 or 3).
    var formatVersion: UInt32 = 0
    /// Version of the quantization scheme (`general.quantization_version`).
    var quantizationVersion: UInt32?
    var tensorCount: UInt64 = 0

    /// Only a tokenizer: a test file, not a model.
    var isVocabularyOnly: Bool { tensorCount == 0 }

    /// Reads the header of a GGUF file; nil when the file isn't one.
    static func read(_ url: URL) -> GGUFInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20), data.count > 24 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> GGUFInfo? {
        var reader = Reader(data: data)
        guard reader.bytes(4) == Data("GGUF".utf8), let version = reader.u32(), (2...3).contains(version),
              let tensors = reader.u64(), let count = reader.u64() else { return nil }
        var info = GGUFInfo(tensorCount: tensors)
        info.formatVersion = version
        for _ in 0..<min(count, 400) {
            guard let key = reader.string(), let type = reader.u32() else { break }
            if key.hasPrefix("tokenizer.") { break }  // big lists follow; the facts we want come before
            if type == 8 {
                guard let value = reader.string() else { break }
                switch key {
                case "general.architecture": info.architecture = value
                case "general.name": info.name = value
                case "general.size_label": info.sizeLabel = value
                case "general.type": info.type = value
                case "general.version": info.version = value
                default: break
                }
            } else if type == 4 {
                guard let value = reader.u32() else { break }
                if key == "general.quantization_version" { info.quantizationVersion = value }
            } else if !reader.skipValue(type) {
                break
            }
        }
        return info
    }

    private struct Reader {
        let data: Data
        var position = 0

        init(data: Data) { self.data = data }

        mutating func bytes(_ n: Int) -> Data? {
            guard n >= 0, position + n <= data.count else { return nil }
            defer { position += n }
            return data.subdata(in: (data.startIndex + position)..<(data.startIndex + position + n))
        }

        mutating func u32() -> UInt32? { bytes(4).map { $0.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } } }
        mutating func u64() -> UInt64? { bytes(8).map { $0.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } } }

        mutating func string() -> String? {
            guard let length = u64(), length < 1 << 20, let raw = bytes(Int(length)) else { return nil }
            return String(decoding: raw, as: UTF8.self)
        }

        /// Steps over a value of the given GGUF type; false when it can't tell how long it is.
        mutating func skipValue(_ type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7: return bytes(1) != nil
            case 2, 3: return bytes(2) != nil
            case 4, 5, 6: return bytes(4) != nil
            case 10, 11, 12: return bytes(8) != nil
            case 8: return string() != nil
            case 9:
                guard let element = u32(), let n = u64(), n < 1 << 24 else { return false }
                var skipped: UInt64 = 0
                while skipped < n {
                    guard skipValue(element) else { return false }
                    skipped += 1
                }
                return true
            default: return false
            }
        }
    }
}
