import AppKit
import AVFoundation
import Observation

@MainActor @Observable
final class TrimVideoModel {
    /// Shared so a clip being edited survives switching to another tool and back.
    static let shared = TrimVideoModel()

    enum SaveState: Equatable {
        case idle
        case saving(Double)
        case done(URL, reencoded: Bool)
        case failed(String)
    }

    static let thumbnailCount = 16

    private(set) var file: URL?
    private(set) var selection = TrimSelection(duration: 0)
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false
    private(set) var thumbnails: [NSImage] = []
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var detail = ""
    private(set) var saveState = SaveState.idle
    private(set) var folder: URL?

    let player = AVPlayer()
    private var timeObserver: Any?
    private var playingSelection = false
    private var thumbnailTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    var hasClip: Bool { file != nil }
    var isSaving: Bool { if case .saving = saveState { true } else { false } }
    var canTrim: Bool { hasClip && !isSaving }

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    // MARK: Loading

    func load(_ url: URL) {
        reset()
        isLoading = true
        file = url
        Task {
            let asset = AVURLAsset(url: url)
            do {
                guard try await asset.load(.isPlayable), let track = try await asset.loadTracks(withMediaType: .video).first
                else { throw TrimError.noVideo }
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw TrimError.noVideo }
                let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
                selection = TrimSelection(duration: duration)
                detail = "\(url.lastPathComponent) · \(Int(abs(size.width))) × \(Int(abs(size.height))) · \(TrimTime.format(duration))"
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                isLoading = false
                loadThumbnails(asset)
                Log.info("Trim video opened", category: "trim", ["seconds": String(Int(duration))])
            } catch {
                file = nil
                isLoading = false
                loadError = (error as? TrimError)?.localizedDescription ?? "This file can't be opened as a video."
                Log.warning("Trim video open failed", category: "trim", ["reason": "\((error as NSError).domain) \((error as NSError).code)"])
            }
        }
    }

    func close() {
        reset()
    }

    private func reset() {
        saveTask?.cancel()
        thumbnailTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        file = nil
        selection = TrimSelection(duration: 0)
        playhead = 0
        isPlaying = false
        playingSelection = false
        thumbnails = []
        loadError = nil
        detail = ""
        saveState = .idle
        folder = nil
    }

    private func loadThumbnails(_ asset: AVAsset) {
        let duration = selection.duration
        thumbnailTask = Task {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            let n = Self.thumbnailCount
            // Middle of each slice, so the strip shows the whole clip evenly.
            let times = (0..<n).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(n), preferredTimescale: 600) }
            var images: [NSImage] = []
            for await result in generator.images(for: times) {
                if Task.isCancelled { return }
                if case .success(_, let image, _) = result {
                    images.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                }
                thumbnails = images
            }
        }
    }

    // MARK: Selection and playback

    func setStart(_ t: Double, scrub: Bool = true) {
        selection.setStart(t)
        if scrub { seek(to: selection.start) }
    }

    func setEnd(_ t: Double, scrub: Bool = true) {
        selection.setEnd(t)
        if scrub { seek(to: selection.end) }
    }

    func setStartToPlayhead() { setStart(playhead, scrub: false) }
    func setEndToPlayhead() { setEnd(playhead, scrub: false) }

    func seek(to t: Double) {
        let clamped = min(max(0, t), selection.duration)
        playhead = clamped
        playingSelection = false
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if isPlaying { player.pause(); playingSelection = false; return }
        if playhead >= selection.duration - 0.05 { seek(to: 0) }
        playingSelection = false
        player.play()
    }

    func playSelection() {
        seek(to: selection.start)
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
        if isPlaying || !player.timeControlStatus.isSeeking { playhead = min(time, selection.duration) }
    }

    // MARK: Saving

    func trim() {
        guard canTrim, let file else { return }
        player.pause()
        saveState = .saving(0)
        let (start, end) = (selection.start, selection.end)
        let folder = Self.makeFolder()
        self.folder = folder
        saveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await VideoTrimmer.trim(source: file, start: start, end: end, into: folder) { p in
                    Task { @MainActor in
                        if case .saving = self.saveState { self.saveState = .saving(p) }
                    }
                }
                saveState = .done(result.url, reencoded: result.reencoded)
                Log.info("Trim finished", category: "trim", ["reencoded": String(result.reencoded), "seconds": String(Int(end - start))])
            } catch is CancellationError {
                saveState = .idle
            } catch {
                saveState = .failed(error.localizedDescription)
                Log.error("Trim failed", category: "trim", ["reason": "\((error as NSError).domain) \((error as NSError).code)"])
            }
        }
    }

    func cancelTrim() { saveTask?.cancel() }

    func reveal() {
        if case .done(let url, _) = saveState { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// A new dated folder in Downloads for each trim, e.g. "Toolbox Videos 2026-10-26 14.30.05".
    private static func makeFolder() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dir = downloads.appendingPathComponent("Toolbox Videos \(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private extension AVPlayer.TimeControlStatus {
    var isSeeking: Bool { self == .waitingToPlayAtSpecifiedRate }
}
