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

        final class Box: @unchecked Sendable { var task: SFSpeechRecognitionTask?; var done = false }
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[TimedWord], Error>) in
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    guard !box.done else { return }
                    if let result {
                        let words = result.bestTranscription.segments.map { TimedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration) }
                        if result.isFinal {
                            box.done = true
                            words.isEmpty ? c.resume(throwing: SpeechError.noSpeech) : c.resume(returning: words)
                        } else if let last = words.last {
                            progress(0.1 + 0.9 * min(last.end / total, 1))
                        }
                    } else if let error {
                        box.done = true
                        let code = (error as NSError).code
                        c.resume(throwing: Task.isCancelled ? CancellationError() : (code == 1110 || code == 203) ? SpeechError.noSpeech : SpeechError.failed)
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}
