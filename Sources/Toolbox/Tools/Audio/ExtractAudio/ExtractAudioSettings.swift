import AVFoundation

enum ExtractAudioFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a = "M4A (AAC)"
    case mp3 = "MP3"
    case wav = "WAV"
    case aiff = "AIFF"

    var id: Self { self }

    var fileExtension: String {
        switch self {
        case .m4a: "m4a"
        case .mp3: "mp3"
        case .wav: "wav"
        case .aiff: "aiff"
        }
    }

    var hasBitrate: Bool { self == .m4a || self == .mp3 }
}

enum ExtractAudioBitrate: Int, CaseIterable, Identifiable, Sendable {
    case kbps128 = 128
    case kbps192 = 192
    case kbps256 = 256
    case kbps320 = 320

    var id: Self { self }
    var label: String { "\(rawValue) kbps" }
    var bitsPerSecond: Int { rawValue * 1000 }
}

struct ExtractAudioSettings: Equatable, Sendable {
    var format = ExtractAudioFormat.m4a
    var bitrate = ExtractAudioBitrate.kbps256

    var summary: String {
        format.hasBitrate ? "\(format.rawValue), \(bitrate.label)" : "\(format.rawValue), uncompressed"
    }
}
