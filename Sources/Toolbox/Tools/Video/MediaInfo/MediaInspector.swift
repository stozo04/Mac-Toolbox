import AVFoundation
import UniformTypeIdentifiers

enum MediaInfoError: LocalizedError {
    case unreadable

    var errorDescription: String? { "This file has no video or audio that macOS can read." }
}

/// Reads a video or audio file and describes it. The file is only ever opened for reading.
enum MediaInspector {
    static func inspect(_ url: URL) async throws -> MediaReport {
        let asset = AVURLAsset(url: url)
        let (tracks, duration, creation, items) = try await asset.load(.tracks, .duration, .creationDate, .metadata)
        guard !tracks.isEmpty else { throw MediaInfoError.unreadable }

        var video: [MediaReport.VideoTrack] = []
        var audio: [MediaReport.AudioTrack] = []
        var other: [MediaReport.OtherTrack] = []
        for track in tracks {
            let (descriptions, rate, fps, size, transform, code, tag) = try await load(track)
            let description = descriptions.first
            let language = languageName(tag ?? code)
            switch track.mediaType {
            case .video:
                video.append(videoTrack(track, description, rate, fps, size, transform, language))
            case .audio:
                audio.append(audioTrack(description, rate, language))
            default:
                other.append(.init(kind: kind(track.mediaType), codec: description.map { MediaFormat.codecName($0.mediaSubType.rawValue) },
                                   language: language))
            }
        }

        let seconds = duration.isNumeric ? max(duration.seconds, 0) : 0
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let size = Int64(values?.fileSize ?? 0)
        let created = try await creation?.load(.dateValue)
        let (location, metadata) = await readMetadata(items)

        return MediaReport(
            fileName: url.lastPathComponent,
            sizeBytes: size,
            container: values?.contentType?.localizedDescription ?? url.pathExtension.uppercased(),
            duration: seconds,
            overallBitrate: seconds > 0 && size > 0 ? Double(size) * 8 / seconds : nil,
            creationDate: created,
            videoTracks: video, audioTracks: audio, otherTracks: other,
            location: location, metadata: metadata)
    }

    // MARK: Tracks

    private static func load(_ track: AVAssetTrack) async throws
        -> ([CMFormatDescription], Float, Float, CGSize, CGAffineTransform, String?, String?) {
        let (d, r, f, s, t) = try await track.load(.formatDescriptions, .estimatedDataRate, .nominalFrameRate, .naturalSize, .preferredTransform)
        let (code, tag) = try await track.load(.languageCode, .extendedLanguageTag)
        return (d, r, f, s, t, code, tag)
    }

    private static func videoTrack(_ track: AVAssetTrack, _ description: CMFormatDescription?, _ rate: Float, _ fps: Float,
                                   _ size: CGSize, _ transform: CGAffineTransform, _ language: String?) -> MediaReport.VideoTrack {
        let rotation = rotation(of: transform)
        let turned = rotation == 90 || rotation == 270
        let subtype = description.map { MediaFormat.fourCCString($0.mediaSubType.rawValue) }
        return .init(
            codec: description.map { MediaFormat.codecName($0.mediaSubType.rawValue) } ?? "Unknown",
            width: Int((turned ? size.height : size.width).rounded()),
            height: Int((turned ? size.width : size.height).rounded()),
            rotation: rotation,
            frameRate: fps > 0 ? Double(fps) : nil,
            bitrate: rate > 0 ? Double(rate) : nil,
            dynamicRange: dynamicRange(description, subtype: subtype, flaggedHDR: track.hasMediaCharacteristic(.containsHDRVideo)),
            colorPrimaries: description.flatMap { string($0, kCMFormatDescriptionExtension_ColorPrimaries) }.map(primariesName),
            bitDepth: description.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int },
            language: language)
    }

    private static func audioTrack(_ description: CMFormatDescription?, _ rate: Float, _ language: String?) -> MediaReport.AudioTrack {
        let basic = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        return .init(
            codec: description.map { MediaFormat.codecName($0.mediaSubType.rawValue) } ?? "Unknown",
            sampleRate: basic.flatMap { $0.mSampleRate > 0 ? $0.mSampleRate : nil },
            channels: basic.flatMap { $0.mChannelsPerFrame > 0 ? Int($0.mChannelsPerFrame) : nil },
            bitDepth: basic.flatMap { $0.mBitsPerChannel > 0 ? Int($0.mBitsPerChannel) : nil },
            bitrate: rate > 0 ? Double(rate) : nil,
            language: language)
    }

    /// Degrees the picture is turned for display, snapped to a quarter turn.
    static func rotation(of t: CGAffineTransform) -> Int {
        let degrees = atan2(Double(t.b), Double(t.a)) * 180 / .pi
        let quarter = Int((degrees / 90).rounded())
        return ((quarter % 4) + 4) % 4 * 90
    }

    private static func dynamicRange(_ d: CMFormatDescription?, subtype: String?, flaggedHDR: Bool) -> String {
        if subtype == "dvh1" || subtype == "dvhe" { return "HDR (Dolby Vision)" }
        let transfer = d.flatMap { string($0, kCMFormatDescriptionExtension_TransferFunction) }
        if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String { return "HDR (HLG)" }
        if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String { return "HDR (PQ)" }
        return flaggedHDR ? "HDR" : "SDR"
    }

    private static func primariesName(_ p: String) -> String {
        let names: [(CFString, String)] = [
            (kCMFormatDescriptionColorPrimaries_ITU_R_709_2, "Rec. 709"), (kCMFormatDescriptionColorPrimaries_ITU_R_2020, "Rec. 2020"),
            (kCMFormatDescriptionColorPrimaries_P3_D65, "Display P3"), (kCMFormatDescriptionColorPrimaries_SMPTE_C, "SMPTE-C"),
            (kCMFormatDescriptionColorPrimaries_EBU_3213, "EBU 3213 (PAL)"),
        ]
        return names.first { $0.0 as String == p }?.1 ?? p
    }

    private static func string(_ d: CMFormatDescription, _ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(d, extensionKey: key) as? String
    }

    private static func kind(_ type: AVMediaType) -> String {
        switch type {
        case .subtitle: "Subtitle"
        case .closedCaption: "Closed caption"
        case .timecode: "Timecode"
        case .text: "Text"
        case .metadata: "Metadata"
        case .muxed: "Muxed"
        default: type.rawValue.capitalized
        }
    }

    /// "eng" -> "English". Nothing for "und" (undetermined).
    private static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    // MARK: Metadata

    private static func readMetadata(_ items: [AVMetadataItem]) async -> (MediaReport.Location?, [MediaReport.MetadataItem]) {
        var location: MediaReport.Location?
        var out: [MediaReport.MetadataItem] = []
        for item in items {
            guard let id = item.identifier?.rawValue else { continue }
            let text = await value(of: item)
            guard let text, !text.isEmpty else { continue }
            if id == AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue
                || id == AVMetadataIdentifier.commonIdentifierLocation.rawValue {
                location = location ?? MediaFormat.parseISO6709(text)
                if location != nil { continue }
            }
            guard let label = label(for: id) else { continue }
            let entry = MediaReport.MetadataItem(label: label, value: String(text.prefix(500)))
            if !out.contains(entry) { out.append(entry) }
        }
        return (location, out)
    }

    private static func value(of item: AVMetadataItem) async -> String? {
        if let s = try? await item.load(.stringValue) { return s }
        if let d = try? await item.load(.dateValue) { return MediaFormat.date(d) }
        if let n = try? await item.load(.numberValue) { return n.stringValue }
        return nil
    }

    /// A readable name for a metadata key, or nil for ones already shown elsewhere (the creation date).
    static func label(for identifier: String) -> String? {
        let known: [String: String] = [
            "mdta/com.apple.quicktime.make": "Camera make", "mdta/com.apple.quicktime.model": "Camera model",
            "mdta/com.apple.quicktime.software": "Software", "common/make": "Camera make", "common/model": "Camera model",
            "common/software": "Software", "common/albumName": "Album", "common/copyrights": "Copyright",
        ]
        if let name = known[identifier] { return name }
        let key = identifier.split(separator: "/").last.map(String.init) ?? identifier
        let word = key.split(separator: ".").last.map(String.init) ?? key
        if word.lowercased() == "creationdate" { return nil }
        var spaced = ""
        for ch in word {
            if ch.isUppercase, !spaced.isEmpty { spaced.append(" ") }
            spaced.append(spaced.isEmpty ? Character(ch.uppercased()) : Character(ch.lowercased()))
        }
        return spaced
    }
}
