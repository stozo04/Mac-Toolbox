import AVFoundation

struct AudioSourceInfo: Equatable, Sendable {
    let duration: Double
    let sampleRate: Double
    let channels: Int
    let sample: SourceSampleFormat

    var summary: String {
        let rate = sampleRate > 0 ? "\((sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz" : nil
        let layout = switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case let n where n > 2: "\(n) channels"
        default: ""
        }
        return [rate, layout.isEmpty ? nil : layout].compactMap { $0 }.joined(separator: " · ")
    }
}

enum AudioWaveform {
    static let barCount = 400
    static let analysisSampleRate = 8_000.0

    static func info(of url: URL) async throws -> AudioSourceInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TrimAudioError.notAudio }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw TrimAudioError.notAudio }
        let stream = try await track.load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sample = SourceSampleFormat(bitDepth: Int(stream?.mBitsPerChannel ?? 0),
                                        isFloat: (stream?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0
                                            && stream?.mFormatID == kAudioFormatLinearPCM,
                                        isAppleLossless: stream?.mFormatID == kAudioFormatAppleLossless)
        return AudioSourceInfo(duration: duration, sampleRate: stream?.mSampleRate ?? 0,
                               channels: Int(stream?.mChannelsPerFrame ?? 0), sample: sample)
    }

    static func peaks(of url: URL, duration: Double, count: Int = barCount) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TrimAudioError.notAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: analysisSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TrimAudioError.notAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TrimAudioError.notAudio }

        var bins = PeakBins(count: count, totalFrames: Int(duration * analysisSampleRate))
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            bins.add(samples(in: buffer))
        }
        if reader.status == .failed { throw reader.error ?? TrimAudioError.notAudio }
        return bins.normalized
    }

    private static func samples(in buffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        let count = length / MemoryLayout<Float>.size
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
        }
        return values
    }
}

struct PeakBins {
    private(set) var values: [Float]
    private let totalFrames: Int
    private var frame = 0

    init(count: Int, totalFrames: Int) {
        values = Array(repeating: 0, count: max(count, 1))
        self.totalFrames = max(totalFrames, 1)
    }

    mutating func add(_ samples: [Float]) {
        let count = values.count
        for sample in samples {
            let bin = min(frame * count / totalFrames, count - 1)
            values[bin] = max(values[bin], abs(sample))
            frame += 1
        }
    }

    var normalized: [Float] {
        guard let loudest = values.max(), loudest > 0 else { return values }
        return values.map { $0 / loudest }
    }
}
