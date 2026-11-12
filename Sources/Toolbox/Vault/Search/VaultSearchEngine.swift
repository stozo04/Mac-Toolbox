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
    private var cancelWork: (() -> Void)?
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

    func pending(_ items: [VaultItem]) async throws -> [VaultItem] {
        try await onQueue { [self] in
            let index = try openIndex()
            let known = try index.files()
            let current = Dictionary(items.map { (relativePath(of: $0.url), $0) }, uniquingKeysWith: { first, _ in first })
            let gone = known.keys.filter { current[$0] == nil }
            if !gone.isEmpty {
                try index.remove(Array(gone))
                cachedVectors = nil
            }
            return items.filter { item in
                guard let stored = known[relativePath(of: item.url)] else { return true }
                return stored != Self.fingerprint(item.url)
            }
        }
    }

    func index(_ item: VaultItem) async throws {
        try await onQueue { [self] in
            let index = try openIndex()
            let embedder = try fullEmbedder()
            try prepareWorkFolder()
            defer { try? FileManager.default.removeItem(at: workFolder) }
            let segments = try embed(item, with: embedder)
            try checkOpen()
            try index.store(path: relativePath(of: item.url), file: Self.fingerprint(item.url), segments: segments)
            cachedVectors = nil
        }
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

    func close() {
        lock.lock()
        closed = true
        let cancel = cancelWork
        lock.unlock()
        cancel?()
        let finished = DispatchSemaphore(value: 0)
        queue.async { [self] in
            index?.close()
            index = nil
            full?.close()
            full = nil
            textOnly?.close()
            textOnly = nil
            cachedVectors = nil
            try? FileManager.default.removeItem(at: workFolder)
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + Self.closeTimeout)
    }

    static func fingerprint(_ url: URL) -> VaultIndexedFile {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return VaultIndexedFile(bytes: bytes, modified: modified)
    }

    private func embed(_ item: VaultItem, with embedder: LlamaEmbedder) throws -> [VaultSegment] {
        switch item.kind {
        case .image:
            let prepared = try MediaPieces.preparePhoto(item.url, to: workFolder)
            let vector = try embedder.embedImage(prepared.path, budget: Self.photoBudget)
            return [VaultSegment(modality: .image, start: 0, end: 0, vector: vector)]
        case .video:
            let url = item.url, folder = workFolder
            let frames = try blocking { try await MediaPieces.videoFrames(of: url, to: folder) }
            var segments: [VaultSegment] = []
            for frame in frames {
                try checkOpen()
                let vector = try embedder.embedImage(frame.file.path, budget: Self.frameBudget)
                segments.append(VaultSegment(modality: .image, start: frame.start, end: frame.end, vector: vector))
                try? FileManager.default.removeItem(at: frame.file)
            }
            let sounds = try blocking { try await MediaPieces.soundtrack(of: url, to: folder) }
            for sound in sounds {
                try checkOpen()
                let vector = try embedder.embedAudio(sound.file.path)
                segments.append(VaultSegment(modality: .audio, start: sound.start, end: sound.end, vector: vector))
                try? FileManager.default.removeItem(at: sound.file)
            }
            return segments
        }
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

    private func blocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        try checkOpen()
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
            done.signal()
        }
        lock.lock()
        cancelWork = { task.cancel() }
        let alreadyClosed = closed
        lock.unlock()
        if alreadyClosed { task.cancel() }
        done.wait()
        lock.lock()
        cancelWork = nil
        lock.unlock()
        try checkOpen()
        return try box.result!.get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
