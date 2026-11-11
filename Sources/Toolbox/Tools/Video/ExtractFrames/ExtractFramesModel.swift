import AppKit
import AVFoundation
import Observation

@MainActor @Observable
final class ExtractFramesModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = ExtractFramesModel()

    enum Status: Equatable {
        case waiting
        case working(Double)
        case done
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        /// How long the picture lasts, and where it starts in the file (usually 0).
        var duration: Double?
        var videoStart = 0.0
        var status = Status.waiting
        /// Saved frames, newest last. Empty for "ZIP only".
        var frames: [URL] = []
        var folder: URL?
        var zip: URL?
        var savedCount = 0
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var notice: String?
    var selectedID: UUID? { didSet { if oldValue != selectedID { loadPlayer() } } }

    var mode = FrameMode.everySeconds
    var interval = 5.0
    var fps = 1
    var total = 10
    var format = FrameFormat.png
    var quality = 0.85
    var maxSide: Int?
    var output = FrameOutput.images
    /// Where the frames go. Nil saves next to each video.
    var customFolder: URL?
    var partOnly = false
    var startText = "0:00.00"
    var endText = ""

    /// The scrubbing player for Pick by hand.
    let player = AVPlayer()
    private(set) var isSavingOne = false
    /// Where the player is, in seconds, for the scrubber.
    private(set) var playhead = 0.0
    @ObservationIgnored private var timeObserver: Any?
    /// Where the last scrub is headed. A seek takes a moment, and Save Frame must use where the user let go,
    /// not where the player still is.
    @ObservationIgnored private var seekTarget: Double?

    private var task: Task<Void, Never>?
    /// Identifies the current run so a cancelled one finishing late can't change the state of a newer one.
    private var runID = UUID()

    init(arguments: [String] = CommandLine.arguments) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            // While a scrub is still seeking, the player reports where it was; keep the thumb where the user put it.
            MainActor.assumeIsolated {
                guard let self, self.seekTarget == nil, time.seconds.isFinite else { return }
                self.playhead = time.seconds
            }
        }
        #if DEBUG
        // Debug aid for checking the filled-in screens: `--frames-files a.mp4,b.mov [--frames-mode manual] [--frames-run]`.
        if let i = arguments.firstIndex(of: "--frames-mode"), i + 1 < arguments.count,
           let m = FrameMode(rawValue: arguments[i + 1]) { mode = m }
        if let i = arguments.firstIndex(of: "--frames-files"), i + 1 < arguments.count {
            add(arguments[i + 1].split(separator: ",").map { URL(fileURLWithPath: String($0)) })
            if arguments.contains("--frames-run") {
                Task { try? await Task.sleep(for: .seconds(1)); extract() }
            }
        }
        #endif
    }

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { isPending($0.status) } }
    /// What Extract Frames will process: the waiting and failed videos, or every video again when all are done
    /// (after changing the options, say). Each run gets its own new folder, so nothing is overwritten.
    var targets: [Item] { hasPending ? items.filter { isPending($0.status) } : items }

    private func isPending(_ status: Status) -> Bool {
        switch status { case .waiting, .failed: true; default: false }
    }
    var doneCount: Int { items.filter { $0.status == .done }.count }
    var selected: Item? { items.first { $0.id == selectedID } }

    /// Nil when the range fields can't be read; the UI shows why.
    var settings: FrameSettings? {
        var s = FrameSettings(mode: mode, interval: max(0.1, interval), fps: fps.clamped(to: FrameSettings.fpsRange),
                              total: total.clamped(to: FrameSettings.totalRange), format: format,
                              quality: quality, maxSide: maxSide, output: output)
        if partOnly && mode != .manual {
            guard let start = TrimTime.parse(startText) else { return nil }
            let endTrimmed = endText.trimmingCharacters(in: .whitespaces)
            let end: Double?
            if endTrimmed.isEmpty { end = nil } else {
                guard let e = TrimTime.parse(endTrimmed), e > start else { return nil }
                end = e
            }
            s.range = (start, end)
        }
        return s
    }

    /// Frames the current settings would save per video, once their lengths are known.
    private var plannedCounts: [Int] {
        guard mode != .manual, let settings else { return [] }
        return targets.compactMap(\.duration).map { FramePlan.times(duration: $0, settings: settings).count }
    }

    /// The batch total, for the "About N frames" line.
    var estimatedCount: Int? { plannedCounts.isEmpty ? nil : plannedCounts.reduce(0, +) }

    /// True when some video would go over the per-video limit and be refused.
    var exceedsLimit: Bool { plannedCounts.contains { $0 > FramePlan.maxFrames } }

    // MARK: Queue

    /// Adds videos; folders are searched for videos inside them.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += BatchFiles.videos(in: url)
            if found.count == before { skipped += 1 }
        }
        var known = Set(items.map { BatchFiles.identity($0.url) })
        // `insert` also drops a video picked twice in one go (a folder plus a file inside it).
        let new = found.filter { known.insert(BatchFiles.identity($0)).inserted }.map { Item(url: $0) }
        items += new
        notice = skipped == 0 ? nil : "\(skipped) item(s) had no videos and were skipped."
        if selectedID == nil { selectedID = items.first?.id }
        for item in new {
            Task {
                let span = await FrameExtractor.videoSpan(of: item.url)
                if let i = items.firstIndex(where: { $0.id == item.id }) {
                    items[i].duration = span?.length
                    items[i].videoStart = span?.start ?? 0
                    // The player was loaded before the start was known; move it to the first real frame.
                    if items[i].id == selectedID, items[i].videoStart > 0 { seek(to: items[i].videoStart) }
                }
            }
        }
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = items.first?.id }
    }

    func clear() {
        task?.cancel()
        runID = UUID()
        items = []
        notice = nil
        isRunning = false
        selectedID = nil
    }

    // MARK: Extracting

    func extract() {
        guard !isRunning, mode != .manual, hasItems, let settings else { return }
        let ids = targets.map(\.id)
        let run = UUID()
        runID = run
        isRunning = true
        for id in ids { update(id) { $0.status = .waiting } }
        let custom = customFolder
        task = Task { [weak self] in
            guard let self else { return }
            defer { if runID == run { isRunning = false } }
            for id in ids {
                if Task.isCancelled || runID != run { break }
                guard let url = items.first(where: { $0.id == id })?.url else { continue }
                update(id) { $0.status = .working(0); $0.frames = [] }
                if selectedID == nil || selected?.status == .done { selectedID = id }
                do {
                    let result = try await FrameExtractor.extract(source: url, settings: settings,
                                                                  destination: try Self.destination(for: url, custom: custom)) { p, frame in
                        Task { @MainActor in
                            self.update(id) {
                                guard case .working = $0.status else { return }
                                $0.status = .working(p)
                                if let frame { $0.frames.append(frame) }
                            }
                        }
                    }
                    update(id) {
                        $0.status = .done
                        $0.savedCount = 0
                        $0.frames = result.frames
                        $0.folder = result.folder
                        $0.zip = result.zip
                        $0.savedCount = result.count
                    }
                    Log.info("Frames extracted", category: "frames",
                             ["mode": settings.mode.rawValue, "format": settings.format.rawValue,
                              "output": settings.output.rawValue, "count": String(result.count)])
                } catch is CancellationError {
                    update(id) { $0.status = .waiting; $0.frames = [] }
                } catch {
                    update(id) { $0.status = .failed(error.localizedDescription); $0.frames = [] }
                    Log.error("Extract frames failed", category: "frames",
                              Log.details(error, file: url, ["mode": settings.mode.rawValue, "format": settings.format.rawValue,
                                                             "output": settings.output.rawValue]))
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Pick by hand: saves the frame under the playhead of the selected video.
    func saveCurrentFrame() {
        guard let item = selected, !isSavingOne, var settings else { return }
        settings.output = .images
        isSavingOne = true
        player.pause()
        let time = seekTarget ?? player.currentTime().seconds
        // Keep adding to this video's folder while it is still in the chosen place; a new "Save to" starts a new one.
        let destination: URL
        do { destination = try Self.destination(for: item.url, custom: customFolder) } catch {
            notice = error.localizedDescription
            isSavingOne = false
            return
        }
        let folder: URL
        if let existing = item.folder, existing.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL {
            folder = existing
        } else {
            folder = FrameExtractor.uniqueFolder(in: destination, name: "\(item.url.deletingPathExtension().lastPathComponent) Frames")
        }
        Task {
            defer { isSavingOne = false }
            do {
                let url = try await FrameExtractor.extractOne(source: item.url, at: time.isFinite ? time : 0,
                                                              settings: settings, folder: folder)
                update(item.id) {
                    $0.folder = folder
                    $0.frames.append(url)
                    $0.savedCount += 1
                    // Status is left alone so the same video can still be run as a batch.
                }
                Log.info("Frame saved by hand", category: "frames", ["format": settings.format.rawValue])
            } catch {
                notice = error.localizedDescription
                Log.error("Save frame failed", category: "frames",
                          Log.details(error, file: item.url, ["time": String(format: "%.3f", time)]))
            }
        }
    }

    func seek(to seconds: Double) {
        player.pause()
        playhead = seconds
        seekTarget = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            Task { @MainActor in if done, self?.seekTarget == seconds { self?.seekTarget = nil } }
        }
    }

    /// Steps the paused player one frame forward or back.
    func step(_ frames: Int) {
        player.pause()
        seekTarget = nil
        player.currentItem?.step(byCount: frames)
        // Stepping back from the first frame must not land in the gap before the picture.
        let start = selected?.videoStart ?? 0
        if start > 0, player.currentTime().seconds < start { seek(to: start) }
    }

    private func loadPlayer() {
        player.pause()
        playhead = 0
        seekTarget = nil
        guard let item = selected else { player.replaceCurrentItem(with: nil); return }
        player.replaceCurrentItem(with: AVPlayerItem(url: item.url))
        // A picture that starts after 0 (an offset track) opens on its first frame, not on the empty gap before it.
        if item.videoStart > 0 { seek(to: item.videoStart) }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    /// The chosen folder; else next to the video, or a dated folder in Downloads when its folder can't be
    /// written (a read-only disk).
    private static func destination(for video: URL, custom: URL?) throws -> URL {
        if let custom {
            // A folder the user picked is never swapped for another one behind their back.
            guard FileManager.default.isWritableFile(atPath: custom.path) else { throw FrameError.folderNotWritable(custom.lastPathComponent) }
            return custom
        }
        let parent = video.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path) { return parent }
        return BatchFiles.makeOutputFolder(named: "Toolbox Frames")
    }

    // MARK: Finder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { customFolder = url }
    }

    /// Where the selected video's frames went, else the last video that saved any: its folder, or the ZIP.
    var savedLocation: URL? { Self.savedLocation(selected: selected, items: items) }

    nonisolated static func savedLocation(selected: Item?, items: [Item]) -> URL? {
        let candidates = [selected].compactMap { $0 } + items.reversed()
        return candidates.lazy.compactMap { $0.folder ?? $0.zip }.first
    }

    func showSaved() {
        guard let location = savedLocation else { return }
        if location.pathExtension.lowercased() == "zip" { reveal(location) } else { open(location) }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func copy(_ url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
    }
}
