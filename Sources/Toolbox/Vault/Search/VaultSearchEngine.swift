import Foundation
import VaultSearch

enum VaultSearchError: LocalizedError {
    case closed
    case notMounted
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .closed: "Search stopped because the vault locked."
        case .notMounted: "The vault isn't open."
        case .modelUnavailable(let reason): "The search model couldn't start: \(reason)"
        }
    }
}

final class VaultSearchEngine: @unchecked Sendable {
    static let photoBudget = 140
    static let frameBudget = 70
    static let closeTimeout: TimeInterval = 3

    let root: URL
    private let model: EmbeddingModel.Located
    private let requiresMountedVolume: Bool
    private let queue = DispatchQueue(label: "toolbox.vault.search", qos: .utility)
    private let lock = NSLock()
    private var closed = false
    private var index: VaultIndex?
    private var full: LlamaEmbedder?
    private var textOnly: LlamaEmbedder?
    private var cachedVectors: VaultVectors?

    init(root: URL, model: EmbeddingModel.Located, requiresMountedVolume: Bool = true) {
        self.root = root
        self.model = model
        self.requiresMountedVolume = requiresMountedVolume
        workFolder = root.appendingPathComponent(VaultLibrary.privateFolderName).appendingPathComponent(Self.workFolderPrefix + UUID().uuidString)
    }

    var privateFolder: URL { root.appendingPathComponent(VaultLibrary.privateFolderName) }
    static let workFolderPrefix = "work-"
    let workFolder: URL

    func relativePath(of url: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    func pending(_ items: [VaultItem], tools: MediaTools? = MediaTools.find()) async throws -> [VaultItem] {
        let (changed, silentVideos) = try await onQueue { [self] in
            let index = try openIndex()
            let known = try index.files()
            let current = Dictionary(items.map { (relativePath(of: $0.url), $0) }, uniquingKeysWith: { first, _ in first })
            let gone = known.keys.filter { current[$0] == nil }
            if !gone.isEmpty {
                try index.remove(Array(gone))
                cachedVectors = nil
            }
            let changed = items.filter { item in
                guard let stored = known[relativePath(of: item.url)] else { return true }
                return stored != Self.fingerprint(item.url)
            }
            let withSound = try index.pathsWithSound()
            let changedIDs = Set(changed.map(\.id))
            let silentVideos = items.filter {
                $0.kind == .video && !changedIDs.contains($0.id) && !withSound.contains(relativePath(of: $0.url))
            }
            return (changed, silentVideos)
        }
        guard tools != nil else { return changed }
        return changed + silentVideos.filter { VaultPlayable.needsSoundRead($0, privateFolder: privateFolder) }
    }

    func index(_ item: VaultItem) async throws {
        try await onQueue { [self] in
            _ = try openIndex()
            _ = try fullEmbedder()
            try prepareWorkFolder()
        }
        do {
            let segments = try await segments(of: item)
            guard !segments.isEmpty else { throw EmbedderError.failed("Nothing in this file could be read.") }
            try await onQueue { [self] in
                try checkOpen()
                try openIndex().store(path: relativePath(of: item.url), file: Self.fingerprint(item.url), segments: segments)
                cachedVectors = nil
            }
        } catch {
            await removeWorkFolder()
            throw error
        }
        await removeWorkFolder()
    }

    func finishIndexing() async {
        try? await onQueue { [self] in
            full?.close()
            full = nil
        }
    }

    func remove(_ items: [VaultItem]) async {
        try? await onQueue { [self] in
            try openIndex().remove(items.map { relativePath(of: $0.url) })
            cachedVectors = nil
        }
    }

    func search(_ text: String, names: [String: String]) async throws -> VaultSearchResult {
        try await onQueue { [self] in
            let vectors = try loadVectors()
            guard vectors.rows > 0 else {
                return VaultRanking.rank(query: text, vectors: vectors, scores: [], names: names)
            }
            let embedder = try queryEmbedder()
            guard let query = try embedder.embedTexts([Prompts.query(text)]).first else { return VaultSearchResult() }
            let scores = Scoring.cosines(query, against: vectors.matrix, rows: vectors.rows)
            return VaultRanking.rank(query: text, vectors: vectors, scores: scores, names: names)
        }
    }

    func shutDown() async {
        markClosed()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                releaseEverything()
                continuation.resume()
            }
        }
    }

    func close() {
        markClosed()
        let finished = DispatchSemaphore(value: 0)
        queue.async { [self] in
            releaseEverything()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + Self.closeTimeout)
    }

    private func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    private func releaseEverything() {
        index?.close()
        index = nil
        full?.close()
        full = nil
        textOnly?.close()
        textOnly = nil
        cachedVectors = nil
        try? FileManager.default.removeItem(at: workFolder)
    }

    static func fingerprint(_ url: URL) -> VaultIndexedFile {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return VaultIndexedFile(bytes: bytes, modified: modified)
    }

    private func segments(of item: VaultItem) async throws -> [VaultSegment] {
        switch item.kind {
        case .image:
            let vector = try await onQueue { [self] in
                try checkOpen()
                let prepared = try MediaPieces.preparePhoto(item.url, to: workFolder)
                return try fullEmbedder().embedImage(prepared.path, budget: Self.photoBudget)
            }
            return [VaultSegment(modality: .image, start: 0, end: 0, vector: vector)]
        case .video:
            try checkOpen()
            var segments: [VaultSegment] = []
            for frame in try await MediaPieces.videoFrames(of: item.url, to: workFolder) {
                try Task.checkCancellation()
                segments.append(try await embed(frame, as: .image))
            }
            let sounds: [MediaPiece]
            do {
                let soundSource = await VaultPlayable.url(for: item, privateFolder: privateFolder)
                sounds = try await MediaPieces.soundtrack(of: soundSource, to: workFolder)
                if soundSource != item.url { VaultPlayable.markSoundRead(item, privateFolder: privateFolder) }
            } catch is CancellationError {
                throw VaultSearchError.closed
            } catch {
                Log.warning("Vault video sound unreadable", category: VaultLog.category, VaultLog.details(error, file: item.url))
                sounds = []
            }
            for sound in sounds {
                try Task.checkCancellation()
                segments.append(try await embed(sound, as: .audio))
            }
            return segments
        }
    }

    private func embed(_ piece: MediaPiece, as modality: Modality) async throws -> VaultSegment {
        try await onQueue { [self] in
            try checkOpen()
            defer { try? FileManager.default.removeItem(at: piece.file) }
            let embedder = try fullEmbedder()
            let vector = modality == .image
                ? try embedder.embedImage(piece.file.path, budget: Self.frameBudget)
                : try embedder.embedAudio(piece.file.path)
            return VaultSegment(modality: modality, start: piece.start, end: piece.end, vector: vector)
        }
    }

    private func removeWorkFolder() async {
        try? await onQueue { [self] in try? FileManager.default.removeItem(at: workFolder) }
    }

    private func openIndex() throws -> VaultIndex {
        try checkOpen()
        if let index { return index }
        try requireMounted()
        if !FileManager.default.fileExists(atPath: privateFolder.path) {
            try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: false)
        }
        let opened = try VaultIndex(at: privateFolder.appendingPathComponent(VaultIndex.fileName))
        index = opened
        removeLeftoverWorkFolders()
        return opened
    }

    private func removeLeftoverWorkFolders() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: privateFolder.path)) ?? []
        for name in names where name.hasPrefix(Self.workFolderPrefix) && name != workFolder.lastPathComponent {
            try? FileManager.default.removeItem(at: privateFolder.appendingPathComponent(name))
        }
    }

    private func loadVectors() throws -> VaultVectors {
        if let cachedVectors { return cachedVectors }
        let loaded = try openIndex().vectors()
        cachedVectors = loaded
        return loaded
    }

    private func fullEmbedder() throws -> LlamaEmbedder {
        if let full { return full }
        textOnly?.close()
        textOnly = nil
        do {
            let made = try LlamaEmbedder(model: model, textOnly: false)
            full = made
            return made
        } catch {
            throw VaultSearchError.modelUnavailable(error.localizedDescription)
        }
    }

    private func queryEmbedder() throws -> LlamaEmbedder {
        if let full { return full }
        if let textOnly { return textOnly }
        do {
            let made = try LlamaEmbedder(model: model, textOnly: true)
            textOnly = made
            return made
        } catch {
            throw VaultSearchError.modelUnavailable(error.localizedDescription)
        }
    }

    private func prepareWorkFolder() throws {
        try requireMounted()
        try? FileManager.default.removeItem(at: workFolder)
        if !FileManager.default.fileExists(atPath: privateFolder.path) {
            try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: false)
        }
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: false)
    }

    private func requireMounted() throws {
        guard !requiresMountedVolume || VaultThumbnails.isMountedVolume(root.path) else { throw VaultSearchError.notMounted }
    }

    private func checkOpen() throws {
        lock.lock()
        defer { lock.unlock() }
        if closed { throw VaultSearchError.closed }
    }

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
