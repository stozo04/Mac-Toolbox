import Foundation
import UniformTypeIdentifiers

/// Which frames to take from each video.
enum FrameMode: String, CaseIterable, Identifiable {
    case everySeconds, perSecond, total, manual
    var id: String { rawValue }

    var title: String {
        switch self {
        case .everySeconds: "Every N seconds"
        case .perSecond: "Frames per second"
        case .total: "Set number"
        case .manual: "Pick by hand"
        }
    }
}

enum FrameFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue == "jpeg" ? "jpg" : rawValue }
    var type: UTType { switch self { case .png: .png; case .jpeg: .jpeg; case .heic: .heic } }
    var isLossy: Bool { self != .png }
}

/// Where the frames end up.
enum FrameOutput: String, CaseIterable, Identifiable {
    case images, imagesAndZip, zipOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .images: "Images"
        case .imagesAndZip: "Images + ZIP"
        case .zipOnly: "ZIP only"
        }
    }
}

struct FrameSettings: Equatable {
    /// Longest-side choices in pixels; nil keeps the original size.
    static let sizes: [Int?] = [nil, 1920, 1280, 640, 320]
    static let fpsRange = 1...30
    static let totalRange = 1...1000

    var mode = FrameMode.everySeconds
    var interval = 5.0
    var fps = 1
    var total = 10
    var format = FrameFormat.png
    /// 0...1, used for JPEG and HEIC.
    var quality = 0.85
    var maxSide: Int?
    var output = FrameOutput.images
    /// Start and end in seconds when only part of each video is used. End nil means to the end.
    var range: (start: Double, end: Double?)?

    static func == (a: FrameSettings, b: FrameSettings) -> Bool {
        a.mode == b.mode && a.interval == b.interval && a.fps == b.fps && a.total == b.total && a.format == b.format
            && a.quality == b.quality && a.maxSide == b.maxSide && a.output == b.output
            && a.range?.start == b.range?.start && a.range?.end == b.range?.end
    }
}

/// The pure arithmetic: which moments to grab and what to call the files.
enum FramePlan {
    /// More frames than this from one video is almost always a mistake (an hour at 30 fps is 108,000).
    static let maxFrames = 5000

    /// The part of the video to use, clamped to it. Nil when nothing is left.
    static func span(duration: Double, range: (start: Double, end: Double?)?) -> (start: Double, end: Double)? {
        guard duration.isFinite, duration > 0 else { return nil }
        let start = max(0, range?.start ?? 0)
        let end = min(duration, range?.end ?? duration)
        return start < end ? (start, end) : nil
    }

    /// The timestamps to grab, starting at the first frame of the span and always before its end.
    /// Empty for `.manual`.
    static func times(duration: Double, settings: FrameSettings) -> [Double] {
        guard let span = span(duration: duration, range: settings.range) else { return [] }
        let length = span.end - span.start
        let step: Double
        switch settings.mode {
        case .manual: return []
        case .everySeconds: step = max(settings.interval, 0.01)
        case .perSecond: step = 1 / Double(settings.fps.clamped(to: FrameSettings.fpsRange))
        case .total:
            let n = settings.total.clamped(to: FrameSettings.totalRange)
            return (0..<n).map { span.start + Double($0) * length / Double(n) }
        }
        // Counting by index instead of adding `step` repeatedly keeps long runs from drifting.
        let count = Int(((length - 1e-9) / step).rounded(.down)) + 1
        return (0..<min(count, maxFrames + 1)).map { span.start + Double($0) * step }
    }

    /// "Clip_0001_00m05.250s.png". The index keeps Finder order right; the time says where the frame came from.
    static func fileName(base: String, index: Int, time: Double, format: FrameFormat) -> String {
        let ms = max(0, Int((time * 1000).rounded()))
        let stamp = String(format: "%02dm%02d.%03ds", ms / 60_000, ms / 1000 % 60, ms % 1000)
        return "\(base)_\(String(format: "%04d", index))_\(stamp).\(format.fileExtension)"
    }

    /// One line for the options panel.
    static func summary(_ settings: FrameSettings) -> String {
        let from = settings.range == nil ? "the first frame" : "the start time"
        switch settings.mode {
        case .everySeconds:
            return "One frame every \(String(format: "%.1f", settings.interval)) s, starting at \(from)."
        case .perSecond:
            return settings.fps == 1 ? "One frame per second of video, starting at \(from)."
                : "\(settings.fps) frames per second of video, starting at \(from)."
        case .total:
            return "\(settings.total) frame\(settings.total == 1 ? "" : "s") spread evenly through each video."
        case .manual:
            return "Scrub to a moment and click Save Frame. Each click saves one image."
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
