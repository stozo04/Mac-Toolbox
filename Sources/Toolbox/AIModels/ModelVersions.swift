import Foundation

/// A model's version and where that number came from, so a guess never passes for a fact.
struct ModelVersion: Equatable {
    var value: String
    /// "recorded in the model", "read from its name"...
    var source: String
    /// The version of the file format it is stored in ("GGUF v3", "Core ML spec 6 · macOS 12 or later").
    var format: String?
}

/// What a Core ML model says about itself in the metadata.json inside its bundle.
struct CoreMLInfo: Equatable {
    var version: String?
    var author: String?
    var specificationVersion: Int?
    var minimumMacOS: String?
    var coreMLToolsVersion: String?

    static func read(bundle: URL) -> CoreMLInfo? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("metadata.json")),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let dict = (json as? [[String: Any]])?.first ?? (json as? [String: Any]) else { return nil }
        let user = dict["userDefinedMetadata"] as? [String: Any]
        func text(_ value: Any?) -> String? {
            let s = (value as? String) ?? (value as? NSNumber)?.stringValue
            return s?.isEmpty == false ? s : nil
        }
        return CoreMLInfo(version: text(dict["version"]), author: text(dict["author"]),
                          specificationVersion: (dict["specificationVersion"] as? NSNumber)?.intValue,
                          minimumMacOS: text((dict["availability"] as? [String: Any])?["macOS"]),
                          coreMLToolsVersion: text(user?["com.github.apple.coremltools.version"]))
    }

    var formatDescription: String? {
        guard let specificationVersion else { return nil }
        return "Core ML spec \(specificationVersion)" + (minimumMacOS.map { " · macOS \($0) or later" } ?? "")
    }
}

enum ModelVersions {
    /// "v3", "v6.2.1" written into names: a "v" and numbers standing on their own.
    static func versionTokens(in text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9])[vV](\d+(?:\.\d+){0,3})(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found: [String] = []
        for match in regex.matches(in: text, range: range) {
            if let r = Range(match.range(at: 1), in: text), !found.contains("v" + text[r]) { found.append("v" + text[r]) }
        }
        return found
    }

    /// The generation in a model's name: "embeddinggemma-2" → 2, "Qwen2.5-7B" → 2.5, "gemma3" → 3. Sizes ("7B", "271M"),
    /// quantizations ("Q8_0") and short family letters ("e5", "md10") are not versions.
    static func generation(inName name: String) -> String? {
        var name = name
        if let quant = ModelKnowledge.quantization(in: name), let range = name.range(of: quant, options: .caseInsensitive) { name.removeSubrange(range) }  // "Q8_0" has a 0 of its own
        let tokens = name.split { " -_".contains($0) }.map(String.init)
        for (i, token) in tokens.enumerated() {
            if let dotted = firstMatch(#"^[A-Za-z]{3,}(\d+(?:\.\d+)*)$"#, in: token) { return dotted }
            if i > 0, token.count <= 3, let plain = firstMatch(#"^(\d+(?:\.\d+)*)$"#, in: token) { return plain }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The version of a single model file or bundle: its own record first, then its name.
    static func version(recorded: String?, names: [String], generationFrom: String?, format: String?) -> ModelVersion? {
        if let recorded { return ModelVersion(value: recorded, source: "recorded in the model", format: format) }
        let tokens = names.flatMap(versionTokens(in:)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !tokens.isEmpty { return ModelVersion(value: tokens.joined(separator: ", "), source: "read from its name", format: format) }
        if let generationFrom, let generation = generation(inName: generationFrom) {
            return ModelVersion(value: generation, source: "read from its name", format: format)
        }
        return format.map { ModelVersion(value: "", source: "", format: $0) }
    }
}
