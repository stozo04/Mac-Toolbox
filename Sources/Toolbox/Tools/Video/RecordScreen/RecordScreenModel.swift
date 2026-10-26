import AppKit
import Observation

@MainActor @Observable
final class RecordScreenModel {
    /// Shared so a running recording survives switching to another tool and back.
    static let shared = RecordScreenModel()

    enum Phase: Equatable { case idle, countdown(Int), starting, recording, finishing }
    enum Access { case unknown, allowed, denied }

    struct Notice: Equatable {
        let message: String
        /// A System Settings pane that fixes it, shown as a button.
        let settingsURL: URL?
    }

    static let screenSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    var kind = RecordingSourceKind.display
    var options = RecordingOptions()
    private(set) var displays: [DisplaySource] = []
    private(set) var windows: [WindowSource] = []
    private(set) var selectedDisplayID: CGDirectDisplayID?
    var selectedWindowID: CGWindowID?
    /// The chosen region in points, from the top-left of the selected display.
    private(set) var area: CGRect?
    private(set) var phase = Phase.idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var savedFile: URL?
    private(set) var access = Access.unknown
    private(set) var isLoading = false
    var notice: Notice?

    private let recorder = ScreenRecorder()
    private let panel = RecordingControlPanel()
    private var runTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var recordingStart = Date()

    var isBusy: Bool { phase != .idle }

    var selectedDisplay: DisplaySource? { displays.first { $0.id == selectedDisplayID } }
    var selectedWindow: WindowSource? { windows.first { $0.id == selectedWindowID } }

    var canRecord: Bool {
        guard access != .denied else { return false }
        switch kind {
        case .display, .area: return selectedDisplay != nil
        case .window: return selectedWindow != nil
        }
    }

    /// One line under the timer saying what will be recorded.
    var sourceSummary: String {
        switch kind {
        case .display:
            return selectedDisplay.map { "Display “\($0.name)”" } ?? "No display selected"
        case .window:
            guard let w = selectedWindow else { return "No window selected" }
            return "Window “\(w.title.isEmpty ? w.app : "\(w.app) – \(w.title)")”"
        case .area:
            guard let area else { return "Drag out an area when you start" }
            return "Area \(Int(area.width)) × \(Int(area.height)) on “\(selectedDisplay?.name ?? "display")”"
        }
    }

    init() {
        recorder.onInterrupted = { [weak self] error in
            Log.warning("Recording interrupted", category: "record", ["reason": Self.describe(error)])
            Task { @MainActor in self?.stop() }
        }
    }

    // MARK: Sources

    func refresh() async {
        guard !isBusy else { return }
        isLoading = true
        defer { isLoading = false }
        if access == .unknown && !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        do {
            let listing = try await CaptureSources.load()
            access = .allowed
            displays = listing.displays
            windows = listing.windows
            if selectedDisplay == nil { selectedDisplayID = displays.first?.id }
            if selectedWindow == nil { selectedWindowID = windows.first?.id }
            loadThumbnails()
        } catch {
            access = .denied
            displays = []
            windows = []
        }
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        guard id != selectedDisplayID else { return }
        selectedDisplayID = id
        area = nil
    }

    func chooseArea() async {
        guard let screen = selectedDisplay?.screen else { return }
        if let rect = await AreaSelector.select(on: screen) { area = rect }
    }

    private func loadThumbnails() {
        thumbnailTask?.cancel()
        let displaySnapshot = displays.map(\.display), windowSnapshot = windows.map(\.window)
        thumbnailTask = Task {
            for d in displaySnapshot {
                let image = await CaptureSources.thumbnail(display: d)
                if Task.isCancelled { return }
                if let i = displays.firstIndex(where: { $0.id == d.displayID }) { displays[i].thumbnail = image }
            }
            for w in windowSnapshot.prefix(30) {
                let image = await CaptureSources.thumbnail(window: w)
                if Task.isCancelled { return }
                if let i = windows.firstIndex(where: { $0.id == w.windowID }) { windows[i].thumbnail = image }
            }
        }
    }

    // MARK: Recording

    func toggle() {
        switch phase {
        case .idle: start()
        case .countdown: cancelCountdown()
        case .recording: stop()
        case .starting, .finishing: break
        }
    }

    func start() {
        guard phase == .idle, canRecord else { return }
        savedFile = nil
        notice = nil
        runTask = Task { await run() }
    }

    func cancelCountdown() {
        guard case .countdown = phase else { return }
        runTask?.cancel()
    }

    private func run() async {
        defer { runTask = nil }
        guard let target = await resolveTarget() else { return }
        let screen = Self.screen(for: target)
        panel.show(model: self, on: screen)
        if options.countdown {
            for n in (1...3).reversed() {
                phase = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    panel.hide()
                    phase = .idle
                    return
                }
            }
        }
        phase = .starting
        let output = Self.uniqueOutputURL(format: options.format)
        do {
            try await recorder.start(target: target, options: options, output: output,
                                     excludedWindowIDs: Set([panel.windowID].compactMap { $0 }),
                                     captureRect: { CaptureSources.captureRect(for: target) })
        } catch {
            panel.hide()
            phase = .idle
            report(error)
            return
        }
        recordingStart = Date()
        elapsed = 0
        phase = .recording
        Log.info("Recording started", category: "record", [
            "source": kind.rawValue, "resolution": options.resolution.rawValue, "fps": String(options.frameRate.rawValue),
            "format": options.format.rawValue, "systemAudio": String(options.systemAudio),
            "microphone": String(options.microphone), "clicks": String(options.highlightClicks),
        ])
        await tick()
    }

    /// Keeps the clock moving until the recording stops.
    private func tick() async {
        while phase == .recording {
            elapsed = Date().timeIntervalSince(recordingStart)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func stop() {
        guard phase == .recording else { return }
        elapsed = Date().timeIntervalSince(recordingStart)
        phase = .finishing
        Task {
            do {
                savedFile = try await recorder.stop()
                Log.info("Recording saved", category: "record", ["seconds": String(Int(elapsed))])
            } catch {
                report(error)
            }
            panel.hide()
            phase = .idle
        }
    }

    func reveal() {
        if let savedFile { NSWorkspace.shared.activateFileViewerSelecting([savedFile]) }
    }

    func open() {
        if let savedFile { NSWorkspace.shared.open(savedFile) }
    }

    // MARK: Helpers

    private func resolveTarget() async -> RecordingTarget? {
        switch kind {
        case .display:
            return selectedDisplay.map { .display($0.display) }
        case .window:
            return selectedWindow.map { .window($0.window) }
        case .area:
            if area == nil { await chooseArea() }
            guard let display = selectedDisplay, let area else { return nil }
            return .area(display.display, area)
        }
    }

    private static func screen(for target: RecordingTarget) -> NSScreen? {
        if case .display(let d) = target { return NSScreen.screen(for: d.displayID) }
        if case .area(let d, _) = target { return NSScreen.screen(for: d.displayID) }
        guard let rect = CaptureSources.captureRect(for: target) else { return NSScreen.main }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        Log.error("Recording failed", category: "record", ["reason": Self.describe(error)])
        if let recorderError = error as? RecorderError {
            let url: URL? = if case .microphoneDenied = recorderError { Self.microphoneSettingsURL } else { nil }
            notice = Notice(message: recorderError.localizedDescription, settingsURL: url)
        } else if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801 {
            access = .denied
        } else {
            notice = Notice(message: error.localizedDescription, settingsURL: nil)
        }
    }

    /// Domain and code only: error text can contain file paths, which never go in the log.
    nonisolated private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    /// In Downloads, named by date. A numeric suffix keeps two recordings in the same second apart.
    private static func uniqueOutputURL(format: RecordingFormat) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = RecordingGeometry.fileName(date: Date(), format: format)
        var url = downloads.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloads.appendingPathComponent((base as NSString).deletingPathExtension + " \(n)." + format.fileExtension)
            n += 1
        }
        return url
    }
}
