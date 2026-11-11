import Foundation

/// Finds the AI models on this Mac: in the folders apps and tools keep them, plus loose files found elsewhere.
struct ModelScanner {
    var home: URL
    /// Where models are gathered (see `ModelMover`).
    var central: URL
    /// Model files found outside the known folders (from Spotlight).
    var extraPaths: [URL] = []

    enum Layout { case generic, huggingFace, ollama }

    struct Root: Equatable {
        var url: URL
        var owner: String?
        var layout = Layout.generic
        var isCentral = false
    }

    static let modelExtensions: Set<String> = ["gguf", "safetensors", "onnx", "mlmodel", "tflite", "ckpt", "pth", "pt", "llamafile"]
    static let bundleExtensions: Set<String> = ["mlmodelc", "mlpackage"]
    static let skippedSuffixes = [".partial", ".part", ".download", ".crdownload", ".tmp"]
    /// Places whose models belong to something else (an app, a build, a repository).
    static let excludedForLooseFiles = [".app/", "/node_modules/", "/.build/", "/DerivedData/", "/Library/Developer/", "/.Trash/", "/.git/",
                                        "/Library/Caches/", "/Library/Application Support/", "/Vendor/", "/Pods/", "/site-packages/"]
    static let looseMinimumBytes: Int64 = 5_000_000
    static let rootMinimumBytes: Int64 = 1_000_000

    // MARK: Where to look

    func roots() -> [Root] {
        let fm = FileManager.default
        var found: [Root] = [Root(url: central, owner: nil, isCentral: true)]
        let known: [(String, String, Layout)] = [
            (".cache/huggingface/hub", "Hugging Face", .huggingFace), (".ollama/models", "Ollama", .ollama),
            (".lmstudio/models", "LM Studio", .generic), (".cache/lm-studio/models", "LM Studio", .generic),
            (".cache/whisper", "Whisper", .generic), (".cache/torch/hub/checkpoints", "PyTorch", .generic),
            ("Library/Application Support/nomic.ai/GPT4All", "GPT4All", .generic), ("jan/models", "Jan", .generic),
        ]
        for (path, owner, layout) in known {
            let url = home.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) { found.append(Root(url: url, owner: owner, layout: layout)) }
        }
        // Apps that keep models in a folder with "model" in its name, up to two levels inside their own folder.
        for base in ["Library/Application Support", "Library/Caches"] {
            for app in subfolders(of: home.appendingPathComponent(base)) {
                for child in subfolders(of: app) {
                    if Self.isModelFolderName(child.lastPathComponent) {
                        found.append(Root(url: child, owner: Self.ownerName(app: app.lastPathComponent, folder: nil)))
                    } else {
                        for grandchild in subfolders(of: child) where Self.isModelFolderName(grandchild.lastPathComponent) {
                            found.append(Root(url: grandchild, owner: Self.ownerName(app: app.lastPathComponent, folder: child.lastPathComponent)))
                        }
                    }
                }
            }
        }
        // The central folder is scanned once, as itself; a folder inside another one is part of it.
        var kept: [Root] = []
        for root in found.sorted(by: { $0.url.pathComponents.count < $1.url.pathComponents.count }) {
            if kept.contains(where: { Self.isInside(root.url, $0.url) }) { continue }
            kept.append(root)
        }
        return kept
    }

    static func isModelFolderName(_ name: String) -> Bool { name.lowercased().contains("model") }

    /// "com.apple.VisualIntelligenceCore" → "Apple Visual Intelligence Core"; "Google"/"Chrome" → "Google Chrome".
    static func ownerName(app: String, folder: String?) -> String {
        if app == "Google", let folder { return "Google " + folder }
        if app.hasPrefix("com.apple.") {
            let rest = String(app.dropFirst("com.apple.".count))
            let spaced = rest.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            return "Apple " + spaced
        }
        return app
    }

    private func subfolders(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // MARK: Scan

    func scan() -> [InstalledModel] {
        var byID: [String: InstalledModel] = [:]
        func add(_ original: InstalledModel) {
            // One identity per model, however it was reached: /var and /private/var, or through a link, are the same place.
            var model = original
            model.url = Self.canonical(model.url)
            model.location = Self.canonical(model.location)
            model.linkedFrom = model.linkedFrom.map(Self.canonicalLink)
            if var existing = byID[model.id] {
                existing.linkedFrom = Array(Set(existing.linkedFrom + model.linkedFrom)).sorted { $0.path < $1.path }
                existing.owner = existing.owner ?? model.owner
                byID[model.id] = existing
            } else {
                byID[model.id] = model
            }
        }
        let roots = roots()
        for root in roots {
            switch root.layout {
            case .huggingFace: huggingFaceModels(root).forEach(add)
            case .ollama: ollamaModels(root).forEach(add)
            case .generic: genericModels(root).forEach(add)
            }
        }
        for model in looseModels(outside: roots) { add(model) }
        // An app's models together, in alphabetical order; loose files last.
        return byID.values.map(settled).sorted { ($0.owner ?? "\u{FFFF}", $0.name) < ($1.owner ?? "\u{FFFF}", $1.name) }
    }

    /// Decides the last things that need to see the whole result: where it sits relative to the central folder.
    private func settled(_ model: InstalledModel) -> InstalledModel {
        var m = model
        if Self.isInside(m.url, central) {
            m.movability = .central
            if m.owner == nil {
                let first = m.url.standardizedFileURL.path.dropFirst(central.standardizedFileURL.path.count + 1).split(separator: "/").first.map(String.init)
                if let first, first != Self.looseFolderName { m.owner = first }
            }
        }
        return m
    }

    static let looseFolderName = "Other"

    // MARK: Generic folders (GGUF, Core ML, ONNX ... files)

    private struct Found {
        var url: URL        // as found, possibly a link
        var real: URL
        var relative: [String]
        var format: String
        var bytes: Int64
        var isBundle: Bool
    }

    private func genericModels(_ root: Root) -> [InstalledModel] {
        var files: [Found] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let base = root.url.standardizedFileURL.pathComponents.count
        for case let url as URL in walker {
            if walker.level > 8 { walker.skipDescendants(); continue }
            let name = url.lastPathComponent.lowercased()
            if Self.skippedSuffixes.contains(where: name.hasSuffix) { continue }
            let relative = Array(url.standardizedFileURL.pathComponents.dropFirst(base))
            let values = try? url.resourceValues(forKeys: Set(keys))
            let ext = url.pathExtension.lowercased()
            if values?.isDirectory == true {
                if Self.bundleExtensions.contains(ext) {
                    walker.skipDescendants()
                    files.append(Found(url: url, real: url, relative: relative, format: "Core ML", bytes: Self.size(ofFolder: url), isBundle: true))
                }
                continue
            }
            let real = values?.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
            if values?.isSymbolicLink == true, (try? real.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != false { continue }
            guard let format = Self.format(of: real) ?? Self.format(of: url) else { continue }
            let bytes = Int64((try? real.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard bytes >= Self.rootMinimumBytes else { continue }
            files.append(Found(url: url, real: real, relative: relative, format: format, bytes: bytes, isBundle: false))
        }
        return models(from: files, root: root)
    }

    private func models(from files: [Found], root: Root) -> [InstalledModel] {
        var out: [InstalledModel] = []
        var groups: [String: [Found]] = [:]
        for file in files {
            if file.isBundle || file.format == "TensorFlow Lite" {
                // The pieces of one pipeline (a speaker detector made of three Core ML models, Chrome's small models) read as one.
                let folders = Array(file.relative.dropLast())
                let key = file.format == "TensorFlow Lite" ? "" : folders.prefix(2).joined(separator: "/")
                if key.isEmpty && file.format != "TensorFlow Lite" { out.append(single(file, root: root)) } else { groups[key, default: []].append(file) }
            } else {
                if file.format == "GGUF", let gguf = GGUFInfo.read(file.real), gguf.isVocabularyOnly { continue }
                out.append(single(file, root: root))
            }
        }
        for (key, members) in groups {
            let folder = key.isEmpty ? root.url : root.url.appendingPathComponent(key)
            let bytes = members.reduce(Int64(0)) { $0 + $1.bytes }
            let label = key.isEmpty ? root.url.lastPathComponent : (key as NSString).lastPathComponent
            let description = ModelKnowledge.describe(label: label, path: key + " " + root.url.lastPathComponent, format: members[0].format, owner: root.owner, gguf: nil)
            // A name the rules chose ("Silero VAD") beats the folder path ("argmaxinc / speakerkit-coreml").
            let ruleChoseName = description.name != ModelKnowledge.displayName(label, nil)
            let name = key.isEmpty || ruleChoseName ? description.name : key.replacingOccurrences(of: "/", with: " / ")
            out.append(InstalledModel(name: name, summary: description.summary,
                                      owner: root.owner, kind: description.kind, format: members[0].format,
                                      tags: description.tags + (members.count > 1 ? ["\(members.count) parts"] : []), version: version(ofGroup: members),
                                      bytes: bytes, url: folder, location: folder, linkedFrom: [],
                                      movability: .managed("Several files that belong together; \(root.owner ?? "the app") expects them where they are."),
                                      parts: members.count))
        }
        return out
    }

    private func single(_ file: Found, root: Root) -> InstalledModel {
        let label = file.real.deletingPathExtension().lastPathComponent
        let gguf = file.format == "GGUF" ? GGUFInfo.read(file.real) : nil
        let owner = root.owner
        let description = ModelKnowledge.describe(label: label, path: file.relative.joined(separator: " "), format: file.format, owner: owner, gguf: gguf)
        let isLink = file.real != file.url
        return InstalledModel(name: description.name, summary: description.summary, owner: owner, kind: description.kind, format: file.format,
                              tags: description.tags, version: version(of: file, label: label, gguf: gguf), bytes: file.bytes, url: file.real, location: file.real.deletingLastPathComponent(),
                              linkedFrom: isLink ? [file.url] : [], movability: movability(of: file.real, owner: owner, single: !file.isBundle))
    }

    /// A model's version from what it records about itself, else from its name.
    private func version(of file: Found, label: String, gguf: GGUFInfo?) -> ModelVersion? {
        var recorded: String?
        var format: String?
        if let gguf {
            recorded = gguf.version
            format = "GGUF v\(gguf.formatVersion)" + (gguf.quantizationVersion.map { " · quantization v\($0)" } ?? "")
        } else if file.isBundle, let info = CoreMLInfo.read(bundle: file.real) {
            recorded = info.version
            format = info.formatDescription
        }
        return ModelVersions.version(recorded: recorded, names: [label], generationFrom: gguf?.name ?? label, format: format)
    }

    /// One version for the several files of a pipeline: what they record, else the "v3" and "v4" in their folder names.
    private func version(ofGroup members: [Found]) -> ModelVersion? {
        let infos = members.filter(\.isBundle).compactMap { CoreMLInfo.read(bundle: $0.real) }
        let recorded = Array(Set(infos.compactMap(\.version))).sorted()
        let formats = Array(Set(infos.compactMap(\.formatDescription))).sorted()
        let format = formats.isEmpty ? nil : formats.joined(separator: " / ")
        if !recorded.isEmpty { return ModelVersion(value: recorded.joined(separator: ", "), source: "recorded in the models", format: format) }
        let names = members.flatMap { $0.relative }
        let tokens = Set(names.flatMap(ModelVersions.versionTokens(in:))).sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        if !tokens.isEmpty { return ModelVersion(value: tokens.joined(separator: ", "), source: "read from the folder names", format: format) }
        return format.map { ModelVersion(value: "", source: "", format: $0) }
    }

    private func movability(of real: URL, owner: String?, single: Bool) -> Movability {
        if Self.isInside(real, central) { return .central }
        if let owner, owner.hasPrefix("Apple ") { return .managed("macOS manages this model and may update or remove it.") }
        if !single { return .managed("A folder of files; folders are not moved automatically.") }
        guard let owner else { return .movable }
        return owner == "DigUp" ? .movable : .managed("\(owner) manages this model and may not find it if it is moved.")
    }

    // MARK: Hugging Face cache

    private func huggingFaceModels(_ root: Root) -> [InstalledModel] {
        subfolders(of: root.url).compactMap { folder in
            let parts = folder.lastPathComponent.components(separatedBy: "--")
            guard parts.first == "models", parts.count >= 3 else { return nil }
            let name = parts.dropFirst().joined(separator: "/")
            let blobs = folder.appendingPathComponent("blobs")
            let bytes = Self.size(ofFolder: FileManager.default.fileExists(atPath: blobs.path) ? blobs : folder)
            guard bytes >= Self.rootMinimumBytes else { return nil }
            let format = Self.huggingFaceFormat(folder)
            let description = ModelKnowledge.describe(label: parts.last ?? name, path: name, format: format, owner: "Hugging Face", gguf: nil)
            return InstalledModel(name: name, summary: description.summary, owner: "Hugging Face", kind: description.kind, format: format,
                                  tags: description.tags, version: Self.huggingFaceVersion(folder, name: name), bytes: bytes, url: folder, location: root.url, linkedFrom: [],
                                  movability: .managed("The Hugging Face cache is organized by its own tools; moving files out would break them."))
        }
    }

    /// "v1.5" if the name says, else the short id of the newest downloaded revision.
    private static func huggingFaceVersion(_ folder: URL, name: String) -> ModelVersion? {
        let tokens = ModelVersions.versionTokens(in: name)
        if !tokens.isEmpty { return ModelVersion(value: tokens.joined(separator: ", "), source: "read from its name", format: nil) }
        let snapshots = folder.appendingPathComponent("snapshots")
        let revisions = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = revisions.max { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                                     ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let revision = newest?.lastPathComponent, revision.count >= 7 else { return nil }
        return ModelVersion(value: String(revision.prefix(7)), source: "Hugging Face revision", format: nil)
    }

    private static func huggingFaceFormat(_ folder: URL) -> String {
        var seen: Set<String> = []
        if let walker = FileManager.default.enumerator(at: folder.appendingPathComponent("snapshots"), includingPropertiesForKeys: nil) {
            for case let url as URL in walker { seen.insert(url.pathExtension.lowercased()) }
        }
        if seen.contains("gguf") { return "GGUF" }
        if seen.contains("safetensors") { return "Safetensors" }
        if seen.contains("onnx") { return "ONNX" }
        if seen.contains("mlpackage") || seen.contains("mlmodelc") { return "Core ML" }
        return "Hugging Face"
    }

    // MARK: Ollama

    private func ollamaModels(_ root: Root) -> [InstalledModel] {
        let manifests = root.url.appendingPathComponent("manifests")
        guard let walker = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [InstalledModel] = []
        let base = manifests.standardizedFileURL.pathComponents.count
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let layers = manifest["layers"] as? [[String: Any]] else { continue }
            let parts = Array(url.standardizedFileURL.pathComponents.dropFirst(base))  // registry, namespace, model, tag
            guard parts.count >= 4 else { continue }
            let (namespace, model, tag) = (parts[parts.count - 3], parts[parts.count - 2], parts[parts.count - 1])
            let name = (namespace == "library" ? model : "\(namespace)/\(model)") + ":" + tag
            let bytes = layers.reduce(Int64(0)) { $0 + ((($1["size"] as? NSNumber)?.int64Value) ?? 0) }
            var gguf: GGUFInfo?
            if let weights = layers.first(where: { ($0["mediaType"] as? String)?.hasSuffix("image.model") == true }),
               let digest = weights["digest"] as? String {
                gguf = GGUFInfo.read(root.url.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-")))
            }
            let description = ModelKnowledge.describe(label: model, path: name, format: "GGUF", owner: "Ollama", gguf: gguf)
            let format = gguf.map { "GGUF v\($0.formatVersion)" }
            let version = gguf?.version.map { ModelVersion(value: $0, source: "recorded in the model", format: format) }
                ?? ModelVersion(value: tag, source: "Ollama tag", format: format)
            out.append(InstalledModel(name: name, summary: description.summary, owner: "Ollama", kind: description.kind, format: "GGUF",
                                      tags: description.tags + [tag], version: version, bytes: bytes, url: url, location: root.url, linkedFrom: [],
                                      movability: .managed("Ollama keeps its models in its own library; it would lose track of them if they were moved.")))
        }
        return out
    }

    // MARK: Loose files found elsewhere

    private func looseModels(outside roots: [Root]) -> [InstalledModel] {
        var out: [InstalledModel] = []
        var modelFolders = Set<URL>()
        for path in extraPaths {
            let url = path.standardizedFileURL
            let text = url.path + (url.hasDirectoryPath ? "/" : "")
            if roots.contains(where: { Self.isInside(url, $0.url) }) || Self.excludedForLooseFiles.contains(where: text.contains) { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let ext = url.pathExtension.lowercased()
            let found: Found
            if isDirectory.boolValue {
                guard Self.bundleExtensions.contains(ext) else { continue }
                found = Found(url: url, real: url, relative: [url.lastPathComponent], format: "Core ML", bytes: Self.size(ofFolder: url), isBundle: true)
            } else {
                let real = url.resolvingSymlinksInPath()
                guard let format = Self.format(of: real) else { continue }
                // A downloaded model keeps its weights in shards beside a config file: that folder is one model, not one per shard.
                if format == "Safetensors", let folder = Self.modelFolder(containing: url) {
                    modelFolders.insert(folder)
                    continue
                }
                let bytes = Int64((try? real.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard bytes >= Self.looseMinimumBytes else { continue }
                if format == "GGUF", let info = GGUFInfo.read(real), info.isVocabularyOnly { continue }
                found = Found(url: url, real: real, relative: [url.lastPathComponent], format: format, bytes: bytes, isBundle: false)
            }
            guard found.bytes >= Self.looseMinimumBytes else { continue }
            out.append(single(found, root: Root(url: url.deletingLastPathComponent(), owner: nil)))
        }
        for folder in Self.outermostFolders(modelFolders) {
            if let model = folderModel(folder) { out.append(model) }
        }
        return out
    }

    // MARK: Model folders (weights in shards beside a config, tokenizer and so on)

    /// Files that say "this folder is one model": Hugging Face style (`config.json`, the shard index) or a pipeline's own manifest.
    static let modelFolderMarkers = ["config.json", "model.safetensors.index.json", "split_model.json", "embedded_config.json", "quantize_config.json"]

    /// How far above a weights file its model folder may be: a pipeline keeps components such as `text_encoder/` one level down.
    static let modelFolderSearchDepth = 2

    /// The model folder a weights file belongs to, else nil. Of the marked folders within reach, the outermost wins,
    /// so a pipeline whose components carry their own `config.json` is one model, not one per component.
    static func modelFolder(containing file: URL) -> URL? {
        var folder = file.deletingLastPathComponent()
        var outermost: URL?
        for _ in 0..<modelFolderSearchDepth {
            if isModelFolder(folder) { outermost = folder }
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path else { break }
            folder = parent
        }
        return outermost
    }

    static func isModelFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return modelFolderMarkers.contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Drops any folder that sits inside another one in the set, so no weights are listed or counted twice.
    static func outermostFolders(_ folders: Set<URL>) -> [URL] {
        let paths = folders.map { $0.standardizedFileURL.path }
        return folders.filter { folder in
            let path = folder.standardizedFileURL.path
            return !paths.contains { $0 != path && path.hasPrefix($0 + "/") }
        }.sorted { $0.path < $1.path }
    }

    /// One model made of a folder of files, such as `qwen3.8-27b-8bit` or `ltx-2.5-mlx-q8`.
    private func folderModel(_ folder: URL) -> InstalledModel? {
        let bytes = Self.size(ofFolder: folder)
        guard bytes >= Self.looseMinimumBytes else { return nil }
        let fm = FileManager.default
        let label = folder.lastPathComponent
        let config = Self.readJSON(folder.appendingPathComponent("config.json"))
        let description = ModelKnowledge.describe(label: label, path: label, format: "Safetensors", owner: nil, gguf: nil)
        let ruleChoseName = description.name != ModelKnowledge.displayName(label, nil)
        var summary = description.summary
        var tags = description.tags
        if config?["vision_config"] != nil {
            let sawVideo = fm.fileExists(atPath: folder.appendingPathComponent("video_preprocessor_config.json").path)
            summary += sawVideo ? " It can also look at pictures and video." : " It can also look at pictures."
            tags.append("Vision")
        }
        if let quant = Self.folderQuantization(folder, label: label, config: config), !tags.contains(quant) { tags.append(quant) }
        let shards = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "safetensors" }.count
        return InstalledModel(name: ruleChoseName ? description.name : Self.folderDisplayName(label), summary: summary, owner: nil,
                              kind: description.kind, format: "Safetensors", tags: tags,
                              version: ModelVersions.version(recorded: nil, names: [label], generationFrom: label, format: nil),
                              bytes: bytes, url: folder, location: folder, linkedFrom: [],
                              movability: .managed("A folder of files; folders are not moved automatically."), parts: max(shards, 1))
    }

    /// "8-bit" from what the model records (`quantization.bits`), else from its folder name ("8bit", "q8"), else "BF16" and the like.
    static func folderQuantization(_ folder: URL, label: String, config: [String: Any]?) -> String? {
        func bits(_ json: [String: Any]?) -> Int? {
            guard let json else { return nil }
            for key in ["quantization", "quantization_config"] {
                if let q = json[key] as? [String: Any], let b = (q["bits"] as? NSNumber)?.intValue { return b }
            }
            return (json["bits"] as? NSNumber)?.intValue
        }
        if let b = bits(config) ?? bits(readJSON(folder.appendingPathComponent("quantize_config.json"))) { return "\(b)-bit" }
        for pattern in [#"(?i)(?<![A-Za-z0-9])(\d{1,2})-?bit"#, #"(?i)(?<![A-Za-z0-9])q(\d)(?![A-Za-z0-9_])"#] {
            if let range = label.range(of: pattern, options: .regularExpression) {
                let digits = label[range].filter(\.isNumber)
                if !digits.isEmpty { return "\(digits)-bit" }
            }
        }
        return ModelKnowledge.quantization(in: label)
    }

    /// "qwen3.8-27b-8bit" → "Qwen3.8 27B 8-bit", "ltx-2.5-mlx-q8" → "LTX 2.5 MLX Q8".
    static func folderDisplayName(_ label: String) -> String {
        let shortCaps: Set<String> = ["ltx", "mlx", "gguf", "tts", "vl", "moe", "gpt"]
        let words = label.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
        return words.map { word -> String in
            let lower = word.lowercased()
            if shortCaps.contains(lower) { return lower.uppercased() }
            if lower.range(of: #"^\d+(\.\d+)?[bm]$"#, options: .regularExpression) != nil { return lower.uppercased() }
            if lower.range(of: #"^(q\d+|bf16|f16|f32)$"#, options: .regularExpression) != nil { return lower.uppercased() }
            if lower.range(of: #"^\d+bit$"#, options: .regularExpression) != nil { return lower.replacingOccurrences(of: "bit", with: "-bit") }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Helpers

    /// "GGUF", "ONNX"... for a model file, nil for anything else.
    static func format(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        switch ext {
        case "gguf", "llamafile": return "GGUF"
        case "safetensors": return "Safetensors"
        case "onnx": return "ONNX"
        case "mlmodel": return "Core ML"
        case "tflite": return "TensorFlow Lite"
        case "ckpt", "pth", "pt": return "PyTorch"
        case "bin": return name.hasPrefix("ggml-") ? "GGML" : (name == "model.bin" || name.hasPrefix("pytorch_model") ? "PyTorch" : nil)
        default: return nil
        }
    }

    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    /// A link's own place: its folder made canonical, the link itself not followed.
    static func canonicalLink(_ url: URL) -> URL { canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent) }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path, root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func size(ofFolder url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
