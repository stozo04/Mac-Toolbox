import AVFoundation

enum ExtractAudioError: LocalizedError, Equatable {
    case noMP3Encoder
    case cannotRead
    case cannotWrite
    case encoderFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMP3Encoder: "The MP3 encoder is missing from this copy of Toolbox."
        case .cannotRead: "The soundtrack of this video can't be read."
        case .cannotWrite: "The audio file could not be saved."
        case .encoderFailed(let detail): detail.isEmpty ? "The audio could not be saved." : "The audio could not be saved: \(detail)"
        }
    }
}

struct ExtractAudioResult: Equatable, Sendable {
    let url: URL
    let copiedAsIs: Bool
    let bytes: Int64
    let duration: Double
}

enum ExtractAudioOutcome: Equatable, Sendable {
    case extracted(ExtractAudioResult)
    case noSoundtrack
}

enum AudioExtractor {
    static let aacFormats: Set<AudioFormatID> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
        kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD,
    ]
    static let maxChannels = 2
    static let maxMonoAACBitrate = 256_000
    static let maxMP3SampleRate = 48_000.0
    private static let fallbackSampleRate = 44_100.0

    static func outputBase(for source: URL) -> String { source.deletingPathExtension().lastPathComponent }

    static func extract(source: URL, into folder: URL, settings: ExtractAudioSettings, ffmpeg: URL? = MediaTools.ffmpeg(),
                        progress: @escaping @Sendable (Double) -> Void) async throws -> ExtractAudioOutcome {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return .noSoundtrack }
        let range = try await track.load(.timeRange)
        let description = try await track.load(.formatDescriptions).first
        let output = BatchFiles.uniqueURL(in: folder, name: outputBase(for: source), ext: settings.format.fileExtension)
        let source = SourceAudio(asset: asset, track: track, range: range, description: description)

        let copiedAsIs = settings.format == .m4a && isAAC(source.stream)
        if copiedAsIs, let ffmpeg {
            try await runFFmpeg(ffmpeg, copyArguments(source: asset.url, output: output), output: output,
                                duration: range.duration.seconds, progress: progress)
        } else if copiedAsIs {
            try await pump(source, read: nil, write: nil, type: .m4a, to: output, progress: progress)
        } else if settings.format == .mp3 {
            guard let ffmpeg else { throw ExtractAudioError.noMP3Encoder }
            let arguments = mp3Arguments(source: asset.url, output: output, bitrate: settings.bitrate,
                                         channels: source.channels, sampleRate: source.sampleRate)
            try await runFFmpeg(ffmpeg, arguments, output: output, duration: range.duration.seconds, progress: progress)
        } else {
            try await transcode(source, settings: settings, to: output, progress: progress)
        }
        return .extracted(ExtractAudioResult(url: output, copiedAsIs: copiedAsIs, bytes: size(of: output), duration: range.duration.seconds))
    }

    static func isAAC(_ stream: AudioStreamBasicDescription?) -> Bool {
        stream.map { aacFormats.contains($0.mFormatID) } ?? false
    }

    static func aacBitrate(_ bitrate: ExtractAudioBitrate, channels: Int) -> Int {
        channels == 1 ? min(bitrate.bitsPerSecond, maxMonoAACBitrate) : bitrate.bitsPerSecond
    }

    static func aacSampleRate(from sourceRate: Double) -> Double { sourceRate > fallbackSampleRate ? 48_000 : fallbackSampleRate }

    // MARK: Copy

    private struct SourceAudio: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let range: CMTimeRange
        let description: CMFormatDescription?

        var stream: AudioStreamBasicDescription? {
            description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        }

        var decoded: AudioStreamBasicDescription? {
            description.flatMap { CMAudioFormatDescriptionGetRichestDecodableFormat($0)?.pointee.mASBD } ?? stream
        }

        var channels: Int { min(max(Int(decoded?.mChannelsPerFrame ?? 2), 1), AudioExtractor.maxChannels) }
        var sampleRate: Double {
            guard let rate = decoded?.mSampleRate, rate > 0 else { return AudioExtractor.fallbackSampleRate }
            return rate
        }
    }

    // MARK: Re-encode on device

    private static func transcode(_ source: SourceAudio, settings: ExtractAudioSettings, to output: URL,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let channels = source.channels
        let isAIFF = settings.format == .aiff
        let sampleRate = settings.format == .m4a ? aacSampleRate(from: source.sampleRate) : source.sampleRate
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: isAIFF,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let written: [String: Any] = settings.format == .m4a
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
               AVEncoderBitRateKey: aacBitrate(settings.bitrate, channels: channels)]
            : pcm
        let type: AVFileType = switch settings.format {
        case .aiff: .aiff
        case .wav: .wav
        default: .m4a
        }

        try await pump(source, read: pcm, write: written, type: type, to: output, progress: progress)
    }

    private static func pump(_ source: SourceAudio, read: [String: Any]?, write: [String: Any]?, type: AVFileType, to output: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let isCopy = write == nil
        let reader = try AVAssetReader(asset: source.asset)
        if !isCopy { reader.timeRange = source.range }
        let readOutput = AVAssetReaderTrackOutput(track: source.track, outputSettings: read)
        readOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readOutput) else { throw ExtractAudioError.cannotRead }
        reader.add(readOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: type)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: write, sourceFormatHint: isCopy ? source.description : nil)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExtractAudioError.cannotWrite }
        writer.add(input)

        do {
            guard reader.startReading() else { throw reader.error ?? ExtractAudioError.cannotRead }
            guard writer.startWriting() else { throw writer.error ?? ExtractAudioError.cannotWrite }
            writer.startSession(atSourceTime: source.range.start)
            var reporter = ProgressReporter(total: source.range.duration.seconds, start: source.range.start.seconds, report: progress)
            while let buffer = readOutput.copyNextSampleBuffer() {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? ExtractAudioError.cannotWrite }
                    try await Task.sleep(for: .milliseconds(5))
                }
                try Task.checkCancellation()
                guard input.append(buffer) else { throw writer.error ?? ExtractAudioError.cannotWrite }
                reporter.reached(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
            }
            try Task.checkCancellation()
            if reader.status == .failed { throw reader.error ?? ExtractAudioError.cannotRead }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? ExtractAudioError.cannotWrite }
            progress(1)
        } catch {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: ffmpeg: lossless copy and MP3 (LAME)

    private static let ffmpegInput = ["-nostdin", "-hide_banner", "-v", "error"]
    private static let firstSoundtrackOnly = ["-map", "0:a:0", "-vn", "-sn", "-dn"]
    private static let progressOutput = ["-progress", "pipe:1", "-nostats", "-y"]

    static func copyArguments(source: URL, output: URL) -> [String] {
        ffmpegInput + ["-i", source.path] + firstSoundtrackOnly + ["-c:a", "copy", "-f", "ipod"] + progressOutput + [output.path]
    }

    static func mp3Arguments(source: URL, output: URL, bitrate: ExtractAudioBitrate, channels: Int, sampleRate: Double) -> [String] {
        var arguments = ffmpegInput + ["-i", source.path] + firstSoundtrackOnly
            + ["-c:a", "libmp3lame", "-b:a", "\(bitrate.rawValue)k", "-ac", "\(channels)"]
        if sampleRate > maxMP3SampleRate { arguments += ["-ar", "\(Int(maxMP3SampleRate))"] }
        return arguments + progressOutput + [output.path]
    }

    private static func runFFmpeg(_ ffmpeg: URL, _ arguments: [String], output: URL, duration: Double,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let parser = FFmpegProgress(total: duration, report: progress)
        let result: Shell.Result
        do {
            result = try await Shell.run(ffmpeg.path, arguments, timeout: .untilCancelled) { parser.feed($0) }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: output)
            let detail = result.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw ExtractAudioError.encoderFailed(detail)
        }
        progress(1)
    }

    // MARK: Helpers

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

struct ProgressReporter {
    static let step = 0.01

    let total: Double
    let start: Double
    let report: @Sendable (Double) -> Void
    private var last = 0.0

    init(total: Double, start: Double = 0, report: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.start = start
        self.report = report
    }

    mutating func reached(_ seconds: Double) {
        guard total > 0, seconds.isFinite else { return }
        let fraction = min(max((seconds - start) / total, 0), 1)
        guard fraction - last >= Self.step else { return }
        last = fraction
        report(fraction)
    }
}

final class FFmpegProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var reporter: ProgressReporter

    init(total: Double, report: @escaping @Sendable (Double) -> Void) {
        reporter = ProgressReporter(total: total, report: report)
    }

    func feed(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        pending += chunk
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "out_time_us", let micro = Double(parts[1]) else { continue }
            reporter.reached(micro / 1_000_000)
        }
    }
}
