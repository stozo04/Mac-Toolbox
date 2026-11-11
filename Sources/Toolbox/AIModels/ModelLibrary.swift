import AppKit
import Observation

/// The models on this Mac, kept current: it watches the folders models live in, asks Spotlight about loose files elsewhere,
/// and looks again when Toolbox comes to the front, so adding or removing a model shows up on its own.
@MainActor @Observable
final class ModelLibrary {
    static let shared = ModelLibrary()

    private(set) var models: [InstalledModel] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    /// When the list last changed (not merely re-checked).
    private(set) var lastChanged: Date?
    /// What changed last, in words: "Added EmbeddingGemma 2". Fades after a few seconds.
    private(set) var changeNote: String?
    private var noteTask: Task<Void, Never>?

    let home: URL
    let central: URL
    private let useSpotlight: Bool

    private var started = false
    private var watcher: FileWatcher?
    private var watchedPaths: [String] = []
    private var poll: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var scanning: Task<Void, Never>?
    private var rescanAfter = false
    private var query: NSMetadataQuery?
    private var spotlightPaths: [URL] = []
    private var observers: [NSObjectProtocol] = []

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, central: URL? = nil, spotlight: Bool = true) {
        self.home = home
        self.central = central ?? home.appendingPathComponent("Library/Application Support/Toolbox/AI Models")
        self.useSpotlight = spotlight
    }

    // MARK: Lifecycle

    /// Starts watching and scans; safe to call again.
    func start() {
        guard !started else { return refresh() }
        started = true
        updateWatcher()
        if useSpotlight { startSpotlight() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        // Folders that did not exist yet (Ollama installed later) can't be watched until they appear.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.updateWatcher()
            }
        }
        refresh()
    }

    func stop() {
        started = false
        watcher?.stop()
        watcher = nil
        watchedPaths = []
        poll?.cancel()
        debounce?.cancel()
        scanning?.cancel()
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// Looks again now, or right after the scan that is running.
    func refresh() {
        guard scanning == nil else { rescanAfter = true; return }
        scan()
    }

    /// Looks again in a moment: many file events arrive together while a model downloads or is deleted.
    func refreshSoon() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: Scanning

    private func scan() {
        isScanning = true
        let scanner = ModelScanner(home: home, central: central, extraPaths: spotlightPaths)
        let home = self.home
        scanning = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [InstalledModel] in
                let scanned = scanner.scan()
                return await ModelAssociations.apply(to: scanned, index: AppIndex.build(home: home))
            }.value
            guard let self, !Task.isCancelled else { return }
            if found != models {
                if hasScanned { announce(from: models, to: found) }
                models = found
                lastChanged = Date()
            }
            hasScanned = true
            isScanning = false
            scanning = nil
            if rescanAfter {
                rescanAfter = false
                refresh()
            }
        }
    }

    /// Says what was added or removed, so a model appearing or vanishing doesn't go unnoticed.
    private func announce(from old: [InstalledModel], to new: [InstalledModel]) {
        let before = Set(old.map(\.id)), after = Set(new.map(\.id))
        let added = new.filter { !before.contains($0.id) }.map(\.name)
        let removed = old.filter { !after.contains($0.id) }.map(\.name)
        func list(_ names: [String]) -> String { names.count > 2 ? "\(names[0]) and \(names.count - 1) more" : names.joined(separator: " and ") }
        var parts: [String] = []
        if !added.isEmpty { parts.append("Added " + list(added)) }
        if !removed.isEmpty { parts.append("Removed " + list(removed)) }
        guard !parts.isEmpty else { return }
        changeNote = parts.joined(separator: ". ")
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.changeNote = nil }
        }
    }

    // MARK: Watching

    /// The folders worth watching that exist right now.
    var watchTargets: [String] {
        [central.path, "Library/Application Support", "Library/Caches", ".cache", ".ollama", ".lmstudio", "jan", "models"]
            .map { $0.hasPrefix("/") ? $0 : home.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func updateWatcher() {
        if !FileManager.default.fileExists(atPath: central.path) { try? FileManager.default.createDirectory(at: central, withIntermediateDirectories: true) }
        let targets = watchTargets
        guard targets != watchedPaths else { return }
        watcher?.stop()
        let central = self.central.path
        let next = FileWatcher(paths: targets) { [weak self] paths in
            guard paths.contains(where: { Self.isRelevant($0, central: central) }) else { return }
            Task { @MainActor in self?.refreshSoon() }
        }
        next.start()
        watcher = next
        watchedPaths = targets
        // A folder that has just appeared may already hold models.
        if started, hasScanned { refreshSoon() }
    }

    /// Whether a changed path could be a model: the model files themselves, or anything in a folder named for models.
    nonisolated static func isRelevant(_ path: String, central: String) -> Bool {
        if path.hasPrefix(central) { return true }
        let lower = path.lowercased()
        if lower.contains("model") || lower.contains("huggingface") || lower.contains(".ollama") || lower.contains("lm-studio") || lower.contains("gpt4all") { return true }
        return ModelScanner.modelExtensions.contains((lower as NSString).pathExtension) || ModelScanner.bundleExtensions.contains((lower as NSString).pathExtension)
    }

    // MARK: Spotlight

    private func startSpotlight() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        let names = ["*.gguf", "*.safetensors", "*.onnx", "*.mlmodel", "*.mlpackage", "*.mlmodelc", "*.tflite", "*.ckpt", "*.pth", "*.llamafile"]
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: names.map { NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey, $0) })
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.collectSpotlight() }
            })
        }
        self.query = query
        query.start()
    }

    private func collectSpotlight() {
        guard let query else { return }
        query.disableUpdates()
        let found = query.results.compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }.map { URL(fileURLWithPath: $0) }
        query.enableUpdates()
        guard Set(found) != Set(spotlightPaths) else { return }
        spotlightPaths = found
        refreshSoon()
    }
}
