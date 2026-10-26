import AVFoundation
import CoreGraphics

enum RecordingSourceKind: String, CaseIterable, Identifiable {
    case display = "Display", window = "Window", area = "Area"
    var id: Self { self }
}

enum RecordingResolution: String, CaseIterable, Identifiable {
    case native = "Native", p1440 = "1440p", p1080 = "1080p", p720 = "720p"
    var id: Self { self }

    /// Tallest the video may be; `nil` keeps every pixel of the source.
    var maxHeight: Int? {
        switch self {
        case .native: nil
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        }
    }
}

enum RecordingFrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30, fps60 = 60
    var id: Self { self }
    var label: String { "\(rawValue) fps" }
}

enum RecordingFormat: String, CaseIterable, Identifiable {
    case mov = "MOV", mp4 = "MP4"
    var id: Self { self }
    var fileType: AVFileType { self == .mov ? .mov : .mp4 }
    var fileExtension: String { rawValue.lowercased() }
}

struct RecordingOptions: Equatable {
    var systemAudio = true
    var microphone = false
    var showPointer = true
    var highlightClicks = false
    var includeToolboxWindows = false
    var countdown = true
    var resolution = RecordingResolution.p1080
    var frameRate = RecordingFrameRate.fps30
    var format = RecordingFormat.mov

    var hasAudio: Bool { systemAudio || microphone }
}

enum RecordingGeometry {
    /// H.264 needs even dimensions. Never scales up, so "1080p" on a small window stays at its own size.
    static func outputSize(nativePixels: CGSize, resolution: RecordingResolution) -> (width: Int, height: Int) {
        var width = nativePixels.width, height = nativePixels.height
        if let cap = resolution.maxHeight, height > CGFloat(cap) {
            width *= CGFloat(cap) / height
            height = CGFloat(cap)
        }
        return (even(width), even(height))
    }

    /// About 0.1 bit per pixel per frame: sharp text at modest size (1080p30 is roughly 6 Mbps).
    static func bitrate(width: Int, height: Int, frameRate: Int) -> Int {
        min(max(Int(Double(width * height * frameRate) * 0.1), 1_000_000), 40_000_000)
    }

    static func fileName(date: Date, format: RecordingFormat) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Toolbox Screen Recording \(f.string(from: date)).\(format.fileExtension)"
    }

    /// "1:05" or "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func even(_ value: CGFloat) -> Int { max(2, Int(value.rounded()) & ~1) }
}
