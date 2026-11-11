import CoreMedia
import Foundation
import VideoToolbox

enum VideoCodec: String, Equatable, Sendable {
    case av1 = "AV1"
    case hevc = "HEVC"
    case h264 = "H.264"
    case vp9 = "VP9"
    case vp8 = "VP8"
    case other = "Other"
    case unknown = ""

    init(ytDlpName: String?) {
        guard let name = ytDlpName?.lowercased(), !name.isEmpty, name != "none" else { self = .unknown; return }
        let prefixes: [(String, VideoCodec)] = [
            ("av01", .av1), ("av1", .av1),
            ("hvc1", .hevc), ("hev1", .hevc), ("h265", .hevc), ("hevc", .hevc), ("bytevc1", .hevc),
            ("avc", .h264), ("h264", .h264),
            ("vp09", .vp9), ("vp9", .vp9), ("vp08", .vp8), ("vp8", .vp8),
        ]
        self = prefixes.first { name.hasPrefix($0.0) }?.1 ?? .other
    }

    func playsOnThisMac(decodesAV1: Bool) -> Bool {
        switch self {
        case .h264, .hevc, .unknown: true
        case .av1: decodesAV1
        case .vp9, .vp8, .other: false
        }
    }

    var preference: Int {
        switch self {
        case .av1: 3
        case .hevc: 2
        case .h264: 1
        case .unknown, .vp9, .vp8, .other: 0
        }
    }
}

struct StreamFormat: Decodable, Equatable, Sendable {
    let formatID: String
    var vcodec: String?
    var acodec: String?
    var width: Int?
    var height: Int?
    var fps: Double?
    var tbr: Double?
    var abr: Double?
    var ext: String?
    var languagePreference: Int?
    var hasDRM: Bool?
    var transport: String?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id", vcodec, acodec, width, height, fps, tbr, abr, ext
        case languagePreference = "language_preference", hasDRM = "has_drm", transport = "protocol"
    }

    init(formatID: String, vcodec: String? = nil, acodec: String? = nil, width: Int? = nil, height: Int? = nil,
         fps: Double? = nil, tbr: Double? = nil, abr: Double? = nil, ext: String? = nil,
         languagePreference: Int? = nil, hasDRM: Bool? = nil, transport: String? = nil) {
        self.formatID = formatID
        self.vcodec = vcodec
        self.acodec = acodec
        self.width = width
        self.height = height
        self.fps = fps
        self.tbr = tbr
        self.abr = abr
        self.ext = ext
        self.languagePreference = languagePreference
        self.hasDRM = hasDRM
        self.transport = transport
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatID = try c.decode(String.self, forKey: .formatID)
        vcodec = try? c.decodeIfPresent(String.self, forKey: .vcodec)
        acodec = try? c.decodeIfPresent(String.self, forKey: .acodec)
        width = Self.int(c, .width)
        height = Self.int(c, .height)
        fps = try? c.decodeIfPresent(Double.self, forKey: .fps)
        tbr = try? c.decodeIfPresent(Double.self, forKey: .tbr)
        abr = try? c.decodeIfPresent(Double.self, forKey: .abr)
        ext = try? c.decodeIfPresent(String.self, forKey: .ext)
        languagePreference = Self.int(c, .languagePreference)
        hasDRM = try? c.decodeIfPresent(Bool.self, forKey: .hasDRM)
        transport = try? c.decodeIfPresent(String.self, forKey: .transport)
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
        return (try? c.decodeIfPresent(Double.self, forKey: key)).flatMap { $0.map(Int.init) }
    }

    var hasVideo: Bool { vcodec != "none" && ext != "mhtml" && shortSide != nil }
    var hasAudio: Bool { acodec != "none" }
    var isAudioOnly: Bool { vcodec == "none" && acodec != nil && hasAudio }
    var isDirectFile: Bool { transport.map { $0.hasPrefix("http") && !$0.contains("m3u8") && !$0.contains("dash") } ?? true }
    var codec: VideoCodec { VideoCodec(ytDlpName: vcodec) }
    var isAAC: Bool { acodec?.lowercased().hasPrefix("mp4a") == true || acodec?.lowercased() == "aac" }
    var isDRCAudio: Bool { formatID.lowercased().contains("drc") }

    var shortSide: Int? {
        switch (width, height) {
        case let (w?, h?): min(w, h)
        case let (nil, h?): h
        case let (w?, nil): w
        default: nil
        }
    }
}

struct FormatChoice: Equatable, Sendable {
    let formatSpec: String
    let width: Int?
    let height: Int?
    let fps: Double?
    let codec: VideoCodec
    let playsInQuickTime: Bool

    var summary: String {
        var parts: [String] = []
        if let width, let height { parts.append("\(width)×\(height)") }
        if let fps, fps > 0 { parts.append("\(Int(fps.rounded())) fps") }
        if codec != .unknown { parts.append(codec.rawValue) }
        return parts.joined(separator: " · ")
    }
}

struct VideoInfo: Decodable {
    let formats: [StreamFormat]?
}

enum FormatPicker {
    static let decodesAV1: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    static func choose(from formats: [StreamFormat], options: DownloadOptions, hasFFmpeg: Bool,
                       decodesAV1: Bool = FormatPicker.decodesAV1) -> FormatChoice? {
        guard options.format != .audio else { return nil }
        let usable = formats.filter { $0.hasVideo && $0.hasDRM != true && (hasFFmpeg || $0.hasAudio) }
        let compatible = usable.filter { $0.codec == .h264 }
        let pool = options.mostCompatible && !compatible.isEmpty ? compatible : usable
        guard let video = best(in: capped(pool, to: options.format.maxHeight), decodesAV1: decodesAV1) else { return nil }

        let audio = video.hasAudio || !hasFFmpeg ? nil : bestAudio(in: formats, aacOnly: options.mostCompatible)
        return FormatChoice(formatSpec: audio.map { "\(video.formatID)+\($0.formatID)" } ?? video.formatID,
                            width: video.width, height: video.height, fps: video.fps, codec: video.codec,
                            playsInQuickTime: video.codec.playsOnThisMac(decodesAV1: decodesAV1))
    }

    private static func capped(_ formats: [StreamFormat], to maxShortSide: Int?) -> [StreamFormat] {
        guard let maxShortSide else { return formats }
        let fitting = formats.filter { ($0.shortSide ?? 0) <= maxShortSide }
        if !fitting.isEmpty { return fitting }
        let smallest = formats.compactMap(\.shortSide).min()
        return formats.filter { $0.shortSide == smallest }
    }

    private static func best(in formats: [StreamFormat], decodesAV1: Bool) -> StreamFormat? {
        formats.max { a, b in
            rank(a, decodesAV1).lexicographicallyPrecedes(rank(b, decodesAV1))
        }
    }

    private static func rank(_ f: StreamFormat, _ decodesAV1: Bool) -> [Double] {
        [Double(f.shortSide ?? 0),
         f.codec.playsOnThisMac(decodesAV1: decodesAV1) ? 1 : 0,
         (f.fps ?? 0).rounded(),
         Double(f.codec.preference),
         f.isDirectFile ? 1 : 0,
         f.tbr ?? 0]
    }

    private static func bestAudio(in formats: [StreamFormat], aacOnly: Bool) -> StreamFormat? {
        let all = formats.filter(\.isAudioOnly)
        let aac = all.filter(\.isAAC)
        let pool = aacOnly && !aac.isEmpty ? aac : all
        return pool.max { a, b in audioRank(a).lexicographicallyPrecedes(audioRank(b)) }
    }

    private static func audioRank(_ f: StreamFormat) -> [Double] {
        [Double(f.languagePreference ?? 0), f.isDRCAudio ? 0 : 1, f.isDirectFile ? 1 : 0, f.abr ?? f.tbr ?? 0]
    }
}
