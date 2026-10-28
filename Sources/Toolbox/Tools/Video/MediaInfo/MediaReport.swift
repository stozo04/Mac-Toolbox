import Foundation

/// Everything Media Info shows about one file. Plain values so it can be copied as text or exported as JSON.
struct MediaReport: Codable, Equatable, Identifiable {
    var id: String { fileName + "\(sizeBytes)" }

    struct VideoTrack: Codable, Equatable {
        var codec: String
        var width: Int
        var height: Int
        /// Degrees the picture is turned for display (0, 90, 180, 270).
        var rotation: Int
        var frameRate: Double?
        var bitrate: Double?
        /// "SDR", "HDR (HLG)", "HDR (PQ)" or "HDR (Dolby Vision)".
        var dynamicRange: String
        var colorPrimaries: String?
        var bitDepth: Int?
        var language: String?
    }

    struct AudioTrack: Codable, Equatable {
        var codec: String
        var sampleRate: Double?
        var channels: Int?
        var bitDepth: Int?
        var bitrate: Double?
        var language: String?
    }

    struct OtherTrack: Codable, Equatable {
        var kind: String
        var codec: String?
        var language: String?
    }

    struct MetadataItem: Codable, Equatable {
        var label: String
        var value: String
    }

    struct Location: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        var altitude: Double?
    }

    var fileName: String
    var sizeBytes: Int64
    var container: String
    var duration: Double
    var overallBitrate: Double?
    var creationDate: Date?
    var videoTracks: [VideoTrack]
    var audioTracks: [AudioTrack]
    var otherTracks: [OtherTrack]
    var location: Location?
    var metadata: [MetadataItem]

    var hasVideo: Bool { !videoTracks.isEmpty }

    // MARK: Export

    /// Plain text for the clipboard. Shows the file name only, never its folder.
    var text: String {
        var out: [String] = []
        func line(_ label: String, _ value: String?) { if let value { out.append("\(label): \(value)") } }

        line("File", fileName)
        line("Size", MediaFormat.bytes(sizeBytes))
        line("Format", container)
        line("Duration", MediaFormat.duration(duration))
        line("Overall bitrate", overallBitrate.map(MediaFormat.bitrate))
        line("Created", creationDate.map(MediaFormat.date))
        for (i, v) in videoTracks.enumerated() {
            out.append("")
            out.append(videoTracks.count > 1 ? "Video track \(i + 1)" : "Video track")
            line("  Codec", v.codec)
            line("  Resolution", MediaFormat.resolution(v.width, v.height))
            line("  Rotation", v.rotation == 0 ? nil : "\(v.rotation)°")
            line("  Frame rate", v.frameRate.map(MediaFormat.frameRate))
            line("  Bitrate", v.bitrate.map(MediaFormat.bitrate))
            line("  Color", v.dynamicRange)
            line("  Color primaries", v.colorPrimaries)
            line("  Bit depth", v.bitDepth.map { "\($0)-bit" })
            line("  Language", v.language)
        }
        for (i, a) in audioTracks.enumerated() {
            out.append("")
            out.append(audioTracks.count > 1 ? "Audio track \(i + 1)" : "Audio track")
            line("  Codec", a.codec)
            line("  Sample rate", a.sampleRate.map(MediaFormat.sampleRate))
            line("  Channels", a.channels.map(MediaFormat.channels))
            line("  Bit depth", a.bitDepth.map { "\($0)-bit" })
            line("  Bitrate", a.bitrate.map(MediaFormat.bitrate))
            line("  Language", a.language)
        }
        for o in otherTracks {
            out.append("")
            out.append("\(o.kind) track")
            line("  Codec", o.codec)
            line("  Language", o.language)
        }
        out.append("")
        out.append("Metadata")
        if let location { out.append("  Location: \(MediaFormat.coordinates(location))") }
        for item in metadata { out.append("  \(item.label): \(item.value)") }
        if location == nil && metadata.isEmpty { out.append("  No metadata is stored in this file.") }
        return out.joined(separator: "\n")
    }

    static func json(_ reports: [MediaReport]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(reports.count == 1 ? AnyEncodable(reports[0]) : AnyEncodable(reports))
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// Wording for numbers and codes.
enum MediaFormat {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// 1:02:03.4 / 2:03.4 / 3.4 s
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Unknown" }
        let tenths = Int((seconds * 10).rounded())
        let h = tenths / 36000, m = tenths / 600 % 60, s = tenths / 10 % 60, t = tenths % 10
        if h > 0 { return String(format: "%d:%02d:%02d.%d", h, m, s, t) }
        if m > 0 { return String(format: "%d:%02d.%d", m, s, t) }
        return String(format: "%d.%d s", s, t)
    }

    static func bitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 { return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000) }
        return String(format: "%.0f kbps", bitsPerSecond / 1000)
    }

    static func resolution(_ w: Int, _ h: Int) -> String { "\(w) × \(h)" }

    static func frameRate(_ fps: Double) -> String {
        let rounded = (fps * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(format: "%.0f fps", rounded) : String(format: "%.2f fps", rounded)
    }

    static func sampleRate(_ hz: Double) -> String {
        let khz = hz / 1000
        return khz == khz.rounded() ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
    }

    static func channels(_ n: Int) -> String {
        switch n {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1 surround"
        case 8: "7.1 surround"
        default: "\(n) channels"
        }
    }

    static func coordinates(_ l: MediaReport.Location) -> String {
        String(format: "%.5f, %.5f", l.latitude, l.longitude)
    }

    static func date(_ d: Date) -> String { d.formatted(date: .long, time: .standard) }

    /// "avc1" -> "H.264 (avc1)". Unknown codes show as the four letters.
    static func codecName(_ fourCC: UInt32) -> String {
        let code = fourCCString(fourCC)
        let names: [String: String] = [
            "avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC (H.265)", "hev1": "HEVC (H.265)",
            "dvh1": "HEVC (Dolby Vision)", "dvhe": "HEVC (Dolby Vision)", "av01": "AV1", "vp09": "VP9", "vp08": "VP8",
            "mp4v": "MPEG-4 Visual", "mp1v": "MPEG-1 Video", "mp2v": "MPEG-2 Video", "jpeg": "Motion JPEG", "mjpa": "Motion JPEG",
            "apch": "ProRes 422 HQ", "apcn": "ProRes 422", "apcs": "ProRes 422 LT", "apco": "ProRes 422 Proxy",
            "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ", "aprn": "ProRes RAW", "aprh": "ProRes RAW HQ",
            "mp4a": "AAC", "aac ": "AAC", "ac-3": "Dolby Digital (AC-3)", "ec-3": "Dolby Digital Plus (E-AC-3)",
            "alac": "Apple Lossless (ALAC)", ".mp3": "MP3", "mp3 ": "MP3", "opus": "Opus", "fLaC": "FLAC", "flac": "FLAC",
            "lpcm": "Linear PCM", "sowt": "PCM (little-endian)", "twos": "PCM (big-endian)", "in24": "PCM 24-bit",
            "in32": "PCM 32-bit", "fl32": "PCM 32-bit float", "ulaw": "µLaw", "alaw": "aLaw",
            "tx3g": "Timed text (3GPP)", "c608": "Closed captions (CEA-608)", "c708": "Closed captions (CEA-708)",
            "wvtt": "WebVTT", "text": "Text", "tmcd": "Timecode",
        ]
        guard let name = names[code] else { return code.trimmingCharacters(in: .whitespaces) }
        return "\(name) (\(code.trimmingCharacters(in: .whitespaces)))"
    }

    static func fourCCString(_ n: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes.map { $0 >= 32 && $0 < 127 ? $0 : 63 }, encoding: .ascii) ?? "????"
    }

    /// Reads an ISO 6709 string such as "+37.3349-122.0090+012.345/".
    static func parseISO6709(_ string: String) -> MediaReport.Location? {
        let s = string.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
        guard let first = s.first, first == "+" || first == "-" else { return nil }
        var numbers: [Double] = []
        var current = ""
        for ch in s {
            if (ch == "+" || ch == "-") && !current.isEmpty {
                guard let n = Double(current) else { return nil }
                numbers.append(n)
                current = ""
            }
            current.append(ch)
        }
        guard let last = Double(current) else { return nil }
        numbers.append(last)
        guard numbers.count >= 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return .init(latitude: numbers[0], longitude: numbers[1], altitude: numbers.count > 2 ? numbers[2] : nil)
    }
}
