import AppKit
import AVFoundation
import Combine
import Observation

@MainActor @Observable
final class TrimAudioModel {
    static let shared = TrimAudioModel()
    static let outputFolderName = "Toolbox Trimmed Audio"
    private static let logCategory = "trimAudio"
    private static let endTolerance = 0.05

    typealias Trim = @Sendable (TrimAudioJob, URL, @escaping @Sendable (Double) -> Void) async throws -> TrimAudioResult
    typealias DecodePeaks = @Sendable (URL, Double) async throws -> [Float]

    enum SaveState: Equatable {
        case idle
        case saving(Double)
        case done(TrimAudioResult)
        case failed(String)
    }

    private(set) var file: URL?
    private(set) var info: AudioSourceInfo?
    private(set) var selection = TrimSelection(duration: 0)
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false
    private(set) var peaks: [Float] = []
    private(set) var waveformFailed = false
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var saveState = SaveState.idle
    private(set) var settings = TrimAudioSettings()

    let player = AVPlayer()
    private var track: AVAssetTrack?
    private var playingSelection = false
    private var loadTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var currentSave: UUID?
    private var timeObserver: Any?
    private let outputParent: URL?
    private let trim: Trim
    private let decodePeaks: DecodePeaks

    var hasClip: Bool { file != nil }
    var isSaving: Bool { if case .saving = saveState { true } else { false } }
    var canSave: Bool { hasClip && !isSaving && (!selection.isWholeClip || !settings.fades.isOff || settings.format != .original) }
    var fadeSeconds: (fadeIn: Double, fadeOut: Double) { settings.fades.seconds(within: selection.length) }
    var plan: TrimAudioPlan? {
        file.map { TrimAudioPlan(sourceExtension: $0.pathExtension, sample: info?.sample ?? SourceSampleFormat(), settings: settings) }
    }

    var detail: String {
        guard let file, let info else { return "" }
        return [file.lastPathComponent, info.summary, TrimTime.format(info.duration)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    init(outputParent: URL? = nil,
         trim: @escaping Trim = { try await AudioTrimmer.trim($0, into: $1, progress: $2) },
         decodePeaks: @escaping DecodePeaks = { try await AudioWaveform.peaks(of: $0, duration: $1) }) {
        self.outputParent = outputParent
        self.trim = trim
        self.decodePeaks = decodePeaks
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    // MARK: Loading

    func load(_ url: URL) {
        reset()
        isLoading = true
        file = url
        loadTask = Task {
            let asset = AVURLAsset(url: url)
            do {
                let info = try await AudioWaveform.info(of: url)
                let track = try await asset.loadTracks(withMediaType: .audio).first
                guard !Task.isCancelled, file == url else { return }
                self.track = track
                self.info = info
                selection = TrimSelection(duration: info.duration)
                let item = AVPlayerItem(asset: asset)
                player.replaceCurrentItem(with: item)
                try await Self.waitUntilReady(item)
                guard !Task.isCancelled, file == url else { return }
                applyFadePreview()
                isLoading = false
                loadWaveform(url, duration: info.duration)
                Log.info("Trim audio opened", category: Self.logCategory,
                         ["seconds": String(Int(info.duration)), "extension": url.pathExtension.lowercased()])
            } catch {
                guard !Task.isCancelled, file == url else { return }
                file = nil
                isLoading = false
                loadError = (error as? TrimAudioError)?.localizedDescription ?? "This file can't be opened as audio."
                Log.warning("Trim audio open failed", category: Self.logCategory, Log.details(error, file: url))
            }
        }
    }

    func close() { reset() }

    var isReadyToPlay: Bool { player.currentItem?.status == .readyToPlay }

    private static func waitUntilReady(_ item: AVPlayerItem) async throws {
        let settled = item.publisher(for: \.status, options: [.initial, .new]).first { $0 != .unknown }
        for await status in settled.values where status == .failed {
            throw item.error ?? TrimAudioError.notAudio
        }
    }

    private func reset() {
        saveTask?.cancel()
        currentSave = nil
        loadTask?.cancel()
        waveformTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        file = nil
        info = nil
        track = nil
        selection = TrimSelection(duration: 0)
        playhead = 0
        isPlaying = false
        playingSelection = false
        peaks = []
        waveformFailed = false
        loadError = nil
        saveState = .idle
    }

    private func loadWaveform(_ url: URL, duration: Double) {
        waveformTask = Task { [decodePeaks] in
            do {
                let decode = Task.detached(priority: .userInitiated) { try await decodePeaks(url, duration) }
                let peaks = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
                if !Task.isCancelled && file == url { self.peaks = peaks }
            } catch is CancellationError {
            } catch {
                if file == url { waveformFailed = true }
                Log.warning("Trim audio waveform failed", category: Self.logCategory, Log.details(error, file: url))
            }
        }
    }

    // MARK: Options

    func setFormat(_ format: TrimAudioFormat) {
        settings.format = format
        clearResult()
    }

    func setFadeIn(_ length: FadeLength) {
        settings.fades.fadeIn = length
        selectionChanged()
    }

    func setFadeOut(_ length: FadeLength) {
        settings.fades.fadeOut = length
        selectionChanged()
    }

    private func selectionChanged() {
        applyFadePreview()
        clearResult()
    }

    private func clearResult() {
        if case .saving = saveState { return }
        saveState = .idle
    }

    private func applyFadePreview() {
        guard let item = player.currentItem, let track else { return }
        let (fadeIn, fadeOut) = fadeSeconds
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(1, at: .zero)
        if fadeIn > 0 {
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: range(selection.start, selection.start + fadeIn))
        }
        if fadeOut > 0 {
            parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range(selection.end - fadeOut, selection.end))
            parameters.setVolume(1, at: time(selection.end))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    private func range(_ start: Double, _ end: Double) -> CMTimeRange { CMTimeRange(start: time(start), end: time(end)) }

    // MARK: Selection and playback

    func setStart(_ t: Double, scrub: Bool = true) {
        selection.setStart(t)
        if scrub { seek(to: selection.start) }
        selectionChanged()
    }

    func setEnd(_ t: Double, scrub: Bool = true) {
        selection.setEnd(t)
        if scrub { seek(to: selection.end) }
        selectionChanged()
    }

    func setStartToPlayhead() { setStart(playhead, scrub: false) }
    func setEndToPlayhead() { setEnd(playhead, scrub: false) }

    func seek(to t: Double) {
        let clamped = min(max(0, t), selection.duration)
        playhead = clamped
        playingSelection = false
        player.seek(to: time(clamped), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            playingSelection = false
            return
        }
        if playhead >= selection.duration - Self.endTolerance { seek(to: 0) }
        playingSelection = false
        player.play()
    }

    func playSelection() {
        guard isReadyToPlay else { return }
        let start = selection.start
        playhead = start
        playingSelection = false
        player.pause()
        player.seek(to: time(start), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in self?.startSelectionPlayback(from: start) }
        }
    }

    private func startSelectionPlayback(from start: Double) {
        guard selection.start == start else { return }
        playingSelection = true
        player.play()
    }

    private func tick(_ time: Double) {
        isPlaying = player.rate != 0
        guard time.isFinite else { return }
        if playingSelection && time >= selection.end {
            player.pause()
            playingSelection = false
            isPlaying = false
            playhead = selection.end
            return
        }
        if isPlaying || player.timeControlStatus != .waitingToPlayAtSpecifiedRate { playhead = min(time, selection.duration) }
    }

    // MARK: Saving

    func save() {
        guard canSave, let file else { return }
        player.pause()
        saveState = .saving(0)
        let job = TrimAudioJob(source: file, start: selection.start, end: selection.end,
                               sample: info?.sample ?? SourceSampleFormat(), settings: settings)
        let save = UUID()
        currentSave = save
        saveTask = Task { [weak self] in
            guard let self else { return }
            let finished = await outcome(of: job, from: file, in: save)
            guard currentSave == save else { return }
            saveState = finished
        }
    }

    private func outcome(of job: TrimAudioJob, from file: URL, in save: UUID) async -> SaveState {
        do {
            let folder = try BatchFiles.makeOutputFolder(named: Self.outputFolderName, in: outputParent)
            let result = try await trim(job, folder) { p in
                Task { @MainActor in
                    if self.currentSave == save, case .saving = self.saveState { self.saveState = .saving(p) }
                }
            }
            Log.info("Trim audio finished", category: Self.logCategory, logContext(job, copied: result.copiedAsIs))
            return .done(result)
        } catch is CancellationError {
            return .idle
        } catch {
            Log.error("Trim audio failed", category: Self.logCategory, Log.details(error, file: file, logContext(job, copied: nil)))
            return .failed(error.localizedDescription)
        }
    }

    func cancelSave() { saveTask?.cancel() }

    func reveal() {
        if case .done(let result) = saveState { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
    }

    private func logContext(_ job: TrimAudioJob, copied: Bool?) -> [String: String] {
        var context = ["format": job.settings.format.rawValue, "seconds": String(Int(job.length)),
                       "fadeIn": job.settings.fades.fadeIn.label, "fadeOut": job.settings.fades.fadeOut.label]
        if let copied { context["copiedAsIs"] = String(copied) }
        return context
    }
}
