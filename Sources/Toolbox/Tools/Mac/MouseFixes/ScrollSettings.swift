import Foundation

struct ScrollSettings: Codable, Equatable {
    /// Flip the direction of the mouse wheel only; trackpads and the Magic Mouse are untouched.
    var reverse = false
    /// A multiplier for how far each wheel click scrolls.
    var speed = 1.0
    /// Turn each wheel click into a short glide, like a trackpad.
    var smooth = false

    static let speedRange = 0.5...5.0

    /// Whether any fix is switched on, i.e. whether Toolbox needs to watch scroll events at all.
    var isActive: Bool { reverse || smooth || abs(speed - 1) > 0.01 }

    var summary: String {
        var parts: [String] = []
        if reverse { parts.append("reversed direction") }
        if abs(speed - 1) > 0.01 { parts.append(String(format: "%.1f× speed", speed).replacingOccurrences(of: ".0×", with: "×")) }
        if smooth { parts.append("smooth scrolling") }
        return parts.joined(separator: ", ")
    }
}

/// How a wheel click is changed. Pure maths, kept apart from the event tap so it can be tested.
enum ScrollTransform {
    /// The new scroll amount, in lines, for one axis of a wheel event.
    static func lines(_ lines: Double, settings: ScrollSettings) -> Double {
        lines * (settings.reverse ? -1 : 1) * settings.speed
    }

    /// Whole lines for the old-style integer field: never rounds a real click down to nothing, keeps its sign.
    static func wholeLines(_ lines: Double) -> Int64 {
        guard lines != 0 else { return 0 }
        let rounded = lines.rounded()
        return Int64(rounded == 0 ? (lines < 0 ? -1 : 1) : rounded)
    }

    static let pixelsPerLine = 32.0
}

/// Spreads a wheel click over several frames so the page glides to a stop. Feed it with `add`, call `tick` every frame.
struct SmoothScroller {
    private(set) var remainingX = 0.0
    private(set) var remainingY = 0.0
    private var carryX = 0.0
    private var carryY = 0.0
    /// Share of the remaining distance covered each frame: higher is snappier.
    var ease = 0.2

    var isIdle: Bool { abs(remainingX) < 0.5 && abs(remainingY) < 0.5 }

    mutating func add(dx: Double, dy: Double) {
        remainingX += dx
        remainingY += dy
    }

    mutating func clear() { self = SmoothScroller(ease: ease) }

    /// The whole pixels to scroll this frame. Fractions are carried over so the total comes out exact.
    mutating func tick() -> (dx: Int32, dy: Int32)? {
        guard !isIdle else {
            // Flush the last fraction so nothing is lost.
            let rest = (dx: Int32((remainingX + carryX).rounded()), dy: Int32((remainingY + carryY).rounded()))
            remainingX = 0; remainingY = 0; carryX = 0; carryY = 0
            return rest.dx == 0 && rest.dy == 0 ? nil : rest
        }
        func step(_ remaining: inout Double, _ carry: inout Double, ease: Double) -> Int32 {
            let move = remaining * ease
            remaining -= move
            carry += move
            let whole = carry.rounded(.towardZero)
            carry -= whole
            return Int32(whole)
        }
        let out = (dx: step(&remainingX, &carryX, ease: ease), dy: step(&remainingY, &carryY, ease: ease))
        return out
    }

    private init(ease: Double) { self.ease = ease }
    init() {}
}
