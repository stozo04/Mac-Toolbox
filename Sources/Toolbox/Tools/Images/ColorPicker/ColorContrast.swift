import Foundation

/// The WCAG 2 contrast ratio of text on a background, and which levels it reaches.
struct ColorContrast: Equatable {
    let ratio: Double

    /// Text that is not large (under 18 pt, or under 14 pt bold) needs 4.5 for AA and 7 for AAA.
    var aaNormal: Bool { ratio >= 4.5 }
    var aaLarge: Bool { ratio >= 3 }
    var aaaNormal: Bool { ratio >= 7 }
    var aaaLarge: Bool { ratio >= 4.5 }

    /// "4.54:1", rounded to two places. A ratio just under a level (4.499) is cut instead, so it never reads as the 4.5 it fails to reach.
    var text: String {
        var shown = (ratio * 100).rounded() / 100
        if Self.levels.contains(where: { ratio < $0 && shown >= $0 }) { shown = (ratio * 100).rounded(.down) / 100 }
        return "\(ColorFormat.number(shown, places: 2)):1"
    }

    private static let levels = [3.0, 4.5, 7.0]

    init(ratio: Double) { self.ratio = ratio }

    /// A color with some transparency is judged as it looks: text over the background, background over white.
    init(text: RGBAColor, background: RGBAColor) {
        let solidBackground = background.composited(over: .white)
        let solidText = text.composited(over: solidBackground)
        let a = solidText.luminance, b = solidBackground.luminance
        self.init(ratio: (max(a, b) + 0.05) / (min(a, b) + 0.05))
    }
}
