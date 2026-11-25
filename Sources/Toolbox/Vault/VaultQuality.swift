import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What can be read about one photo or video, line by line, with the numbers that say which copy is better. Read with
/// Media Info's `MediaInspector` and ImageIO, the same readers the Details sheet uses.
struct VaultQuality: Equatable {
    /// How close two values must be to count as the same.
    enum Tolerance: Equatable {
        case exact
        case absolute(Double)
        case relative(Double)

        func same(_ a: Double, _ b: Double) -> Bool {
            switch self {
            case .exact: a == b
            case .absolute(let gap): abs(a - b) <= gap
            case .relative(let share): abs(a - b) <= max(a, b) * share
            }
        }
    }

    struct Line: Equatable, Identifiable {
        let label: String
        let value: String
        /// Higher is better. Nil for a line where neither value is better, such as the codec.
        var score: Double?
        var tolerance: Tolerance = .exact
        var id: String { label }
    }

    var lines: [Line]
    var pixels: Int?
    var bitrate: Double?
    var frameRate: Double?

    static let bitrateTolerance = Tolerance.relative(0.02)
    static let frameRateTolerance = Tolerance.absolute(0.05)

    func line(_ label: String) -> Line? { lines.first { $0.label == label } }

    /// `playable` is the lossless copy the vault plays, for a file whose sound AVFoundation can't read.
    static func read(_ item: VaultItem, inVault: Bool, playable: URL? = nil) async -> VaultQuality {
        var quality: VaultQuality
        switch item.kind {
        case .video: quality = await video(item.url, playable: playable ?? item.url)
        case .image: quality = image(item.url)
        }
        quality.lines += fileLines(item, inVault: inVault)
        return quality
    }

    static func resolutionLabel(width: Int, height: Int) -> String {
        let short = min(width, height)
        let steps = [(2160, "4K"), (1440, "1440p"), (1080, "1080p"), (720, "720p"), (576, "576p"), (480, "480p")]
        return steps.first { short >= $0.0 }?.1 ?? "\(short)p"
    }

    private static func video(_ url: URL, playable: URL) async -> VaultQuality {
        guard let report = try? await MediaInspector.inspect(url) else {
            return VaultQuality(lines: [Line(label: "Video", value: "Can't be read")])
        }
        var quality = VaultQuality(lines: [], bitrate: report.overallBitrate)
        if let video = report.videoTracks.first {
            let (width, height) = (video.width, video.height)
            quality.pixels = width * height
            quality.frameRate = video.frameRate
            quality.lines.append(Line(label: "Resolution", value: "\(width) × \(height) · \(resolutionLabel(width: width, height: height))",
                                      score: Double(width * height)))
            if let fps = video.frameRate {
                quality.lines.append(Line(label: "Frame rate", value: MediaFormat.frameRate(fps), score: fps, tolerance: frameRateTolerance))
            }
            quality.lines.append(Line(label: "Video codec", value: video.codec))
            if let depth = video.bitDepth { quality.lines.append(Line(label: "Bit depth", value: "\(depth)-bit", score: Double(depth))) }
            quality.lines.append(Line(label: "Dynamic range", value: video.dynamicRange, score: video.dynamicRange == "SDR" ? 0 : 1))
            if let primaries = video.colorPrimaries { quality.lines.append(Line(label: "Color", value: primaries)) }
        }
        if let bitrate = report.overallBitrate {
            quality.lines.append(Line(label: "Bitrate", value: MediaFormat.bitrate(bitrate), score: bitrate, tolerance: bitrateTolerance))
        }
        if let trackBitrate = report.videoTracks.first?.bitrate {
            quality.lines.append(Line(label: "Video bitrate", value: MediaFormat.bitrate(trackBitrate), score: trackBitrate,
                                      tolerance: bitrateTolerance))
        }
        quality.lines += await soundLines(report, original: url, playable: playable)
        quality.lines.append(Line(label: "Length", value: VaultTime.label(report.duration)))
        quality.lines.append(Line(label: "Container", value: report.container))
        if let created = report.creationDate {
            quality.lines.append(Line(label: "Recorded", value: created.formatted(date: .abbreviated, time: .shortened)))
        }
        quality.lines.append(Line(label: "Location", value: report.location == nil ? "None" : "Included"))
        quality.lines += report.metadata.map { Line(label: $0.label, value: $0.value) }
        return quality
    }

    private static func soundLines(_ report: MediaReport, original: URL, playable: URL) async -> [Line] {
        var audio = report.audioTracks.first
        var note = ""
        if audio == nil, playable != original, let copy = try? await MediaInspector.inspect(playable) {
            audio = copy.audioTracks.first
            note = ", played from a lossless copy"
        }
        guard let audio else { return [Line(label: "Sound", value: "No sound", score: 0)] }
        var lines = [Line(label: "Sound", value: audio.codec + note, score: 1)]
        if let bitrate = audio.bitrate {
            lines.append(Line(label: "Audio bitrate", value: MediaFormat.bitrate(bitrate), score: bitrate, tolerance: bitrateTolerance))
        }
        if let rate = audio.sampleRate { lines.append(Line(label: "Sample rate", value: MediaFormat.sampleRate(rate), score: rate)) }
        if let channels = audio.channels {
            lines.append(Line(label: "Channels", value: MediaFormat.channels(channels), score: Double(channels)))
        }
        return lines
    }

    private static func image(_ url: URL) -> VaultQuality {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return VaultQuality(lines: [Line(label: "Image", value: "Can't be read")])
        }
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) { swap(&width, &height) }
        var lines = [Line(label: "Dimensions", value: "\(width) × \(height) · \(resolutionLabel(width: width, height: height))",
                          score: Double(width * height))]
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        lines.append(Line(label: "Format", value: type?.localizedDescription ?? url.pathExtension.uppercased()))
        if let depth = properties[kCGImagePropertyDepth] as? Int { lines.append(Line(label: "Bit depth", value: "\(depth)-bit", score: Double(depth))) }
        if let profile = properties[kCGImagePropertyProfileName] as? String { lines.append(Line(label: "Color profile", value: profile)) }
        let hasGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        lines.append(Line(label: "Dynamic range", value: hasGainMap ? "HDR (gain map)" : "SDR", score: hasGainMap ? 1 : 0))
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let camera = [tiff?[kCGImagePropertyTIFFMake] as? String, tiff?[kCGImagePropertyTIFFModel] as? String].compactMap { $0 }
        if !camera.isEmpty { lines.append(Line(label: "Camera", value: camera.joined(separator: " "))) }
        if let lens = exif?[kCGImagePropertyExifLensModel] as? String { lines.append(Line(label: "Lens", value: lens)) }
        if let taken = exif?[kCGImagePropertyExifDateTimeOriginal] as? String { lines.append(Line(label: "Taken", value: taken)) }
        lines.append(Line(label: "Location", value: properties[kCGImagePropertyGPSDictionary] == nil ? "None" : "Included"))
        return VaultQuality(lines: lines, pixels: width * height)
    }

    private static func fileLines(_ item: VaultItem, inVault: Bool) -> [Line] {
        var lines = [Line(label: "Size", value: ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)),
                     Line(label: "Name", value: item.name)]
        if inVault {
            lines.append(Line(label: "Added to vault", value: item.added.formatted(date: .abbreviated, time: .shortened)))
        }
        if let created = (try? item.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
            lines.append(Line(label: "File created", value: created.formatted(date: .abbreviated, time: .shortened)))
        }
        return lines
    }
}

/// Several copies side by side: one row per line any copy has, which copies are better on it, and which copy is
/// higher quality overall.
struct VaultQualityComparison: Equatable {
    struct Row: Equatable, Identifiable {
        let label: String
        let values: [String?]
        let better: Set<Int>
        let differs: Bool
        var id: String { label }
    }

    let rows: [Row]
    /// The copy that wins on pixels, then bitrate, then frame rate. Nil when none wins: "Same quality".
    let best: Int?

    init(_ copies: [VaultQuality], kind: VaultItem.Kind) {
        let labels = Self.mergedLabels(copies)
        rows = labels.map { label in
            let lines = copies.map { $0.line(label) }
            let values = lines.map { $0?.value }
            return Row(label: label, values: values, better: Self.better(lines),
                       differs: Set(values.compactMap { $0 }).count > 1 || values.contains(nil))
        }
        best = Self.best(copies, kind: kind)
    }

    /// Every copy's lines in reading order: a line only some copies have sits right after the line before it there.
    static func mergedLabels(_ copies: [VaultQuality]) -> [String] {
        var labels: [String] = []
        for copy in copies {
            var after: String?
            for line in copy.lines {
                if !labels.contains(line.label) {
                    let spot = after.flatMap { labels.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                    labels.insert(line.label, at: spot)
                }
                after = line.label
            }
        }
        return labels
    }

    private static func better(_ lines: [VaultQuality.Line?]) -> Set<Int> {
        let scored = lines.enumerated().compactMap { index, line -> (Int, Double, VaultQuality.Tolerance)? in
            guard let line, let score = line.score else { return nil }
            return (index, score, line.tolerance)
        }
        guard scored.count == lines.count, let top = scored.map(\.1).max(),
              let tolerance = scored.first?.2 else { return [] }
        let winners = Set(scored.filter { tolerance.same($0.1, top) }.map(\.0))
        return winners.count == lines.count ? [] : winners
    }

    private static func best(_ copies: [VaultQuality], kind: VaultItem.Kind) -> Int? {
        var contenders = Array(copies.indices)
        let measures: [(KeyPath<VaultQuality, Double?>, VaultQuality.Tolerance)] = kind == .image
            ? [(\.pixelCount, .exact)]
            : [(\.pixelCount, .exact), (\.bitrate, VaultQuality.bitrateTolerance), (\.frameRate, VaultQuality.frameRateTolerance)]
        for (measure, tolerance) in measures {
            let values = contenders.map { copies[$0][keyPath: measure] }
            guard !values.contains(nil) else { return nil }
            guard let top = values.compactMap({ $0 }).max() else { return nil }
            contenders = contenders.filter { copies[$0][keyPath: measure].map { tolerance.same($0, top) } ?? false }
            if contenders.count == 1 { return contenders.first }
        }
        return nil
    }
}

private extension VaultQuality {
    var pixelCount: Double? { pixels.map(Double.init) }
}
