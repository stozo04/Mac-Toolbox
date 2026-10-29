import Foundation

/// A color in sRGB, each part from 0 to 1. The one type every Color Picker format is made from.
struct RGBAColor: Equatable, Hashable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// From 0...255 parts.
    init(r: Int, g: Int, b: Int, a: Int = 255) {
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: Double(a) / 255)
    }

    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let white = RGBAColor(red: 1, green: 1, blue: 1)

    private static func clamp(_ v: Double) -> Double { v.isNaN ? 0 : min(1, max(0, v)) }

    // MARK: Parts

    var r255: Int { Int((red * 255).rounded()) }
    var g255: Int { Int((green * 255).rounded()) }
    var b255: Int { Int((blue * 255).rounded()) }
    var a255: Int { Int((alpha * 255).rounded()) }

    /// Rounded to the 8-bit steps a screen and a HEX code can show, so two picks of the same pixel are equal.
    var quantized: RGBAColor { RGBAColor(r: r255, g: g255, b: b255, a: a255) }

    /// The same color fully opaque.
    var opaque: RGBAColor { RGBAColor(red: red, green: green, blue: blue) }

    /// This color laid over `backdrop`, which is what a translucent color looks like on screen.
    func composited(over backdrop: RGBAColor) -> RGBAColor {
        let backAlpha = backdrop.alpha * (1 - alpha)
        let outAlpha = alpha + backAlpha
        guard outAlpha > 0 else { return .black.withAlpha(0) }
        func mix(_ top: Double, _ back: Double) -> Double { (top * alpha + back * backAlpha) / outAlpha }
        return RGBAColor(red: mix(red, backdrop.red), green: mix(green, backdrop.green), blue: mix(blue, backdrop.blue), alpha: outAlpha)
    }

    func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(red: red, green: green, blue: blue, alpha: alpha) }

    // MARK: Spaces

    /// Hue 0..<360, saturation and lightness 0...1.
    var hsl: (h: Double, s: Double, l: Double) {
        let hi = max(red, green, blue), lo = min(red, green, blue)
        let l = (hi + lo) / 2
        let d = hi - lo
        guard d > 1e-9 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        switch hi {
        case red: h = (green - blue) / d + (green < blue ? 6 : 0)
        case green: h = (blue - red) / d + 2
        default: h = (red - green) / d + 4
        }
        h *= 60
        return (h.truncatingRemainder(dividingBy: 360), min(1, s), l)
    }

    init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let s = min(1, max(0, saturation)), l = min(1, max(0, lightness))
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    /// Light-to-dark value of one channel with the sRGB curve removed.
    static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encoded(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    /// OKLab, the space where equal steps look equal. Used for the OKLCH value and to compare colors.
    var oklab: (l: Double, a: Double, b: Double) {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Lightness 0...1, chroma, hue in degrees. Hue is 0 for greys, which have none.
    var oklch: (l: Double, c: Double, h: Double) {
        let lab = oklab
        let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        guard c > 0.0004 else { return (lab.l, 0, 0) }
        var h = atan2(lab.b, lab.a) * 180 / .pi
        if h < 0 { h += 360 }
        return (lab.l, c, h)
    }

    /// How different two colors look, as the straight distance in OKLab (about 0.02 is the least you can tell apart).
    func distance(to other: RGBAColor) -> Double {
        let a = oklab, b = other.oklab
        let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// WCAG relative luminance, 0 for black and 1 for white.
    var luminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }
}

// MARK: - Showing a color

/// The ways Color Picker can hand a color over.
enum ColorFormat: String, CaseIterable, Identifiable {
    case hex, rgb, hsl, oklch, swiftUI, nsColor, uiColor, tailwind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .oklch: "OKLCH"
        case .swiftUI: "SwiftUI"
        case .nsColor: "NSColor"
        case .uiColor: "UIColor"
        case .tailwind: "Tailwind"
        }
    }

    /// Swift code rather than a color value.
    var isCode: Bool { self == .swiftUI || self == .nsColor || self == .uiColor }

    /// The text that gets copied. With `includeAlpha` off the opacity is left out and the color is shown solid.
    func string(for color: RGBAColor, includeAlpha: Bool) -> String {
        let a = includeAlpha ? color.alpha : 1
        let showsAlpha = includeAlpha
        switch self {
        case .hex:
            let base = String(format: "#%02X%02X%02X", color.r255, color.g255, color.b255)
            return showsAlpha ? base + String(format: "%02X", color.a255) : base
        case .rgb:
            let parts = "\(color.r255), \(color.g255), \(color.b255)"
            return showsAlpha ? "rgba(\(parts), \(Self.number(a, places: 2)))" : "rgb(\(parts))"
        case .hsl:
            let hsl = color.hsl
            let parts = "\(Int(hsl.h.rounded()) % 360), \(Int((hsl.s * 100).rounded()))%, \(Int((hsl.l * 100).rounded()))%"
            return showsAlpha ? "hsla(\(parts), \(Self.number(a, places: 2)))" : "hsl(\(parts))"
        case .oklch:
            let lch = color.oklch
            let parts = "\(Self.number(lch.l, places: 3)) \(Self.number(lch.c, places: 3)) \(Self.number(lch.h, places: 1))"
            return showsAlpha ? "oklch(\(parts) / \(Self.number(a, places: 2)))" : "oklch(\(parts))"
        case .swiftUI:
            let parts = "red: \(Self.number(color.red, places: 3)), green: \(Self.number(color.green, places: 3)), blue: \(Self.number(color.blue, places: 3))"
            return showsAlpha ? "Color(\(parts), opacity: \(Self.number(a, places: 2)))" : "Color(\(parts))"
        case .nsColor:
            return "NSColor(srgbRed: \(Self.channels(color)), alpha: \(Self.number(a, places: 2)))"
        case .uiColor:
            return "UIColor(red: \(Self.channels(color)), alpha: \(Self.number(a, places: 2)))"
        case .tailwind:
            let name = TailwindColors.nearest(to: color).name
            return showsAlpha && color.alpha < 1 ? "\(name)/\(Int((color.alpha * 100).rounded()))" : name
        }
    }

    /// "0.431, green: 0.561, blue: 0.62" - the label of the first part is written by the caller.
    private static func channels(_ c: RGBAColor) -> String {
        "\(number(c.red, places: 3)), green: \(number(c.green, places: 3)), blue: \(number(c.blue, places: 3))"
    }

    /// 0.5, 0.431, 1 - the fewest digits that keep `places` decimals.
    static func number(_ value: Double, places: Int) -> String {
        var s = String(format: "%.\(places)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }
}

// MARK: - Typing a color

extension RGBAColor {
    /// Reads `#6E8F9E`, `6e8f9e`, `#fff`, `#6E8F9E80`, `rgb(110, 143, 158)`, `rgba(110 143 158 / 50%)`, `hsl(200, 18%, 53%)`.
    /// Returns nil when the text is not a color.
    static func parse(_ text: String) -> RGBAColor? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if let open = t.firstIndex(of: "("), t.hasSuffix(")") {
            let name = t[..<open].trimmingCharacters(in: .whitespaces)
            let body = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
            switch name {
            case "rgb", "rgba": return parseRGB(body)
            case "hsl", "hsla": return parseHSL(body)
            default: return nil
            }
        }
        return parseHex(t)
    }

    private static func parseHex(_ text: String) -> RGBAColor? {
        var s = Substring(text)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard [3, 4, 6, 8].contains(s.count), s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count <= 4 { s = Substring(s.map { "\($0)\($0)" }.joined()) }
        var value: UInt64 = 0
        guard Scanner(string: String(s)).scanHexInt64(&value) else { return nil }
        if s.count == 6 {
            return RGBAColor(r: Int(value >> 16) & 255, g: Int(value >> 8) & 255, b: Int(value) & 255)
        }
        return RGBAColor(r: Int(value >> 24) & 255, g: Int(value >> 16) & 255, b: Int(value >> 8) & 255, a: Int(value) & 255)
    }

    /// The numbers inside the brackets, split on commas, spaces or a slash.
    private static func parts(_ body: String) -> [String] {
        body.split(whereSeparator: { ",/ \t".contains($0) }).map(String.init)
    }

    private static func parseRGB(_ body: String) -> RGBAColor? {
        let p = parts(body)
        guard p.count == 3 || p.count == 4 else { return nil }
        var channels: [Double] = []
        for item in p.prefix(3) {
            if item.hasSuffix("%") {
                guard let v = Double(item.dropLast()) else { return nil }
                channels.append(v / 100)
            } else {
                guard let v = Double(item) else { return nil }
                channels.append(v / 255)
            }
        }
        guard let alpha = p.count == 4 ? parseAlpha(p[3]) : 1 else { return nil }
        return RGBAColor(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
    }

    private static func parseHSL(_ body: String) -> RGBAColor? {
        let p = parts(body)
        guard p.count == 3 || p.count == 4 else { return nil }
        guard let h = Double(p[0].replacingOccurrences(of: "deg", with: "")),
              let s = Double(p[1].replacingOccurrences(of: "%", with: "")),
              let l = Double(p[2].replacingOccurrences(of: "%", with: "")),
              let alpha = p.count == 4 ? parseAlpha(p[3]) : 1 else { return nil }
        return RGBAColor(hue: h, saturation: s / 100, lightness: l / 100, alpha: alpha)
    }

    /// "0.5" or "50%".
    private static func parseAlpha(_ text: String) -> Double? {
        if text.hasSuffix("%") { return Double(text.dropLast()).map { $0 / 100 } }
        return Double(text)
    }
}
