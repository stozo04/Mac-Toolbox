import Foundation

/// The part of the clip to keep, in seconds.
struct TrimSelection: Equatable {
    let duration: Double
    private(set) var start: Double = 0
    private(set) var end: Double

    init(duration: Double) {
        self.duration = max(duration, 0)
        end = self.duration
    }

    /// Shortest allowed selection, so the handles can never cross.
    var minimumLength: Double { min(0.1, duration / 2) }
    var length: Double { end - start }
    var isWholeClip: Bool { start <= 0 && end >= duration }

    mutating func setStart(_ t: Double) { start = min(max(0, t), end - minimumLength) }
    mutating func setEnd(_ t: Double) { end = max(min(duration, t), start + minimumLength) }
}

enum TrimTime {
    /// "0:05.25", or "1:02:03.50" past an hour.
    static func format(_ seconds: Double) -> String {
        let cs = max(0, Int((seconds * 100).rounded()))
        let (h, m, s, c) = (cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, c) : String(format: "%d:%02d.%02d", m, s, c)
    }

    /// Accepts "62.5", "1:02.5" and "1:02:03.5". Returns nil for anything else.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            guard let v = Double(part), v >= 0, v.isFinite else { return nil }
            // Only the last field may carry a fraction.
            if i < parts.count - 1 && v != v.rounded() { return nil }
            total = total * 60 + v
        }
        return total
    }
}
