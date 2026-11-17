import Foundation

enum TrimAudioFormat: String, CaseIterable, Identifiable, Sendable {
    case original = "Same as Original"
    case mp3 = "MP3"
    case m4a = "M4A (AAC)"
    case wav = "WAV"
    case flac = "FLAC"
    case aiff = "AIFF"

    var id: Self { self }

    var container: AudioContainer? {
        switch self {
        case .original: nil
        case .mp3: .mp3
        case .m4a: .m4a
        case .wav: .wav
        case .flac: .flac
        case .aiff: .aiff
        }
    }
}

enum AudioContainer: Equatable, Sendable {
    case mp3, m4a, wav, flac, aiff

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "mp3": self = .mp3
        case "m4a", "mp4", "aac": self = .m4a
        case "wav", "wave": self = .wav
        case "flac": self = .flac
        case "aiff", "aif", "aifc": self = .aiff
        default: return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .mp3: "mp3"
        case .m4a: "m4a"
        case .wav: "wav"
        case .flac: "flac"
        case .aiff: "aiff"
        }
    }

    func isLossless(for sample: SourceSampleFormat) -> Bool {
        switch self {
        case .wav, .aiff, .flac: true
        case .m4a: sample.isAppleLossless
        case .mp3: false
        }
    }

    func encoderArguments(for sample: SourceSampleFormat) -> [String] {
        switch self {
        case .mp3: ["-c:a", "libmp3lame", "-b:a", TrimAudioPlan.mp3Bitrate]
        case .m4a: sample.isAppleLossless ? ["-c:a", "alac"] : ["-c:a", "aac", "-b:a", TrimAudioPlan.aacBitrate]
        case .wav: ["-c:a", sample.pcmCodec(endian: "le")]
        case .aiff: ["-c:a", sample.pcmCodec(endian: "be")]
        case .flac: ["-c:a", "flac"]
        }
    }
}

struct SourceSampleFormat: Equatable, Sendable {
    var bitDepth = 0
    var isFloat = false
    var isAppleLossless = false

    func pcmCodec(endian: String) -> String {
        if isFloat { return "pcm_f\(bitDepth > 32 ? 64 : 32)\(endian)" }
        let bits = switch bitDepth {
        case 25...: 32
        case 17...24: 24
        default: 16
        }
        return "pcm_s\(bits)\(endian)"
    }
}

enum FadeLength: Double, CaseIterable, Identifiable, Sendable {
    case off = 0
    case half = 0.5
    case one = 1
    case two = 2
    case three = 3
    case five = 5
    case ten = 10

    var id: Self { self }
    var label: String { self == .off ? "Off" : "\(rawValue.formatted()) s" }
}

struct TrimFades: Equatable, Sendable {
    var fadeIn = FadeLength.off
    var fadeOut = FadeLength.off

    var isOff: Bool { fadeIn == .off && fadeOut == .off }

    func seconds(within length: Double) -> (fadeIn: Double, fadeOut: Double) {
        let fadeIn = min(fadeIn.rawValue, max(length, 0))
        let fadeOut = min(fadeOut.rawValue, max(length - fadeIn, 0))
        return (fadeIn, fadeOut)
    }
}

struct TrimAudioSettings: Equatable, Sendable {
    var format = TrimAudioFormat.original
    var fades = TrimFades()
}

struct TrimAudioPlan: Equatable, Sendable {
    static let mp3Bitrate = "320k"
    static let aacBitrate = "256k"
    static let fallback = AudioContainer.m4a

    let fileExtension: String
    let codecArguments: [String]
    let copiesAsIs: Bool
    let keepsSoundUnchanged: Bool

    init(sourceExtension: String, sample: SourceSampleFormat, settings: TrimAudioSettings) {
        let sourceExtension = sourceExtension.lowercased()
        let sourceContainer = AudioContainer(fileExtension: sourceExtension)
        let untouched = settings.format == .original && settings.fades.isOff
        if untouched && !sourceExtension.isEmpty && !(sourceContainer?.isLossless(for: sample) ?? false) {
            fileExtension = sourceExtension
            codecArguments = ["-c:a", "copy"]
            copiesAsIs = true
            keepsSoundUnchanged = true
            return
        }
        let container = settings.format.container ?? sourceContainer ?? Self.fallback
        let target = settings.format == .original ? sample : SourceSampleFormat(bitDepth: sample.bitDepth, isFloat: sample.isFloat)
        fileExtension = container.fileExtension
        codecArguments = container.encoderArguments(for: target)
        copiesAsIs = false
        keepsSoundUnchanged = untouched
    }
}
