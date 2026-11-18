import AVFoundation
import Speech

enum SpeechError: LocalizedError {
    case needsPackagedApp
    case notAuthorized
    case unsupportedLanguage
    case noSpeech
    case failed

    var errorDescription: String? {
        switch self {
        case .needsPackagedApp: "Speech recognition needs the packaged Toolbox app. It is not available when run from the command line."
        case .notAuthorized: "Toolbox is not allowed to use speech recognition. Allow it in System Settings > Privacy & Security > Speech Recognition."
        case .unsupportedLanguage: "This language can't be transcribed on this Mac yet."
        case .noSpeech: "No speech was found in this video."
        case .failed: "The speech could not be transcribed."
        }
    }
}

/// Turns the speech in a video or audio file into timed words, entirely on this Mac.
enum SpeechTranscriber {
    /// Languages this Mac can transcribe without sending audio anywhere.
    static var onDeviceLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            .sorted { name(of: $0) < name(of: $1) }
    }

    static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// The Mac's own language if it can be transcribed, else US English, else the first one available.
    static func defaultLocale(in locales: [Locale]) -> Locale? {
        let current = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return locales.first { $0.identifier.replacingOccurrences(of: "_", with: "-") == current }
            ?? locales.first { $0.identifier.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }
            ?? locales.first { $0.identifier == "en_US" } ?? locales.first
    }

    /// Asking for permission from a program without a usage description in its Info.plist ends the process.
    static func canAskForPermission(bundle: Bundle = .main) -> Bool {
        bundle.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    static func transcribe(_ source: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        guard canAskForPermission() else { throw SpeechError.needsPackagedApp }
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw SpeechError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else { throw SpeechError.unsupportedLanguage }

        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-speech-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw SpeechError.noSpeech }
        let total = max(try await asset.load(.duration).seconds, 0.1)
        try await AssetExporter.export(asset, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: audio) { progress($0 * 0.1) }

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        let answer = CancellableAnswer<[TimedWord]>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[TimedWord], Error>) in
                guard answer.accepts(c) else { return }
                let task = recognizer.recognitionTask(with: request) { result, error in
                    let words = result?.bestTranscription.segments.map { TimedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration) }
                    let finalWords = result?.isFinal == true ? words : nil
                    if let outcome = outcome(finalWords: finalWords, error: result == nil ? error : nil, cancelled: answer.isCancelled) {
                        answer.resume(with: outcome)
                    } else if let last = words?.last {
                        progress(0.1 + 0.9 * min(last.end / total, 1))
                    }
                }
                answer.onCancel { task.cancel() }
            }
        } onCancel: {
            answer.cancel()
        }
    }

    private static let noSpeechErrorCodes: Set<Int> = [1110, 203]

    static func outcome(finalWords: [TimedWord]?, error: Error?, cancelled: Bool) -> Result<[TimedWord], Error>? {
        if cancelled { return .failure(CancellationError()) }
        if let finalWords { return finalWords.isEmpty ? .failure(SpeechError.noSpeech) : .success(finalWords) }
        guard let error else { return nil }
        return .failure(noSpeechErrorCodes.contains((error as NSError).code) ? SpeechError.noSpeech : SpeechError.failed)
    }
}

/// A callback runs outside the Swift task, so `Task.isCancelled` is always false there; the cancel is recorded here instead.
/// Cancelling answers the waiting task at once, because the API may never call back after it is told to stop.
final class CancellableAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var stopWork: (() -> Void)?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func accepts(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        let begin = !cancelled
        if begin { self.continuation = continuation }
        lock.unlock()
        if !begin { continuation.resume(throwing: CancellationError()) }
        return begin
    }

    func onCancel(_ stop: @escaping () -> Void) {
        lock.lock()
        let stopNow = cancelled
        if !stopNow { stopWork = stop }
        lock.unlock()
        if stopNow { stop() }
    }

    func resume(with result: Result<Value, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        stopWork = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let stop = stopWork
        lock.unlock()
        stop?()
        resume(with: .failure(CancellationError()))
    }
}
