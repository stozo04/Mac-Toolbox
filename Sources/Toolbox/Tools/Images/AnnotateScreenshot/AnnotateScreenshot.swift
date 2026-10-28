import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tools

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, text, highlight, step, pen, blur, crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .highlight: "Highlighter"
        case .step: "Numbered Step"
        case .pen: "Pen"
        case .blur: "Blur"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .step: "1.circle.fill"
        case .pen: "pencil.tip"
        case .blur: "drop.halffull"
        case .crop: "crop"
        }
    }

    /// The key that picks the tool.
    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "e"
        case .text: "t"
        case .highlight: "h"
        case .step: "n"
        case .pen: "p"
        case .blur: "b"
        case .crop: "c"
        }
    }

    init?(key: Character) {
        guard let tool = Self.allCases.first(where: { $0.key == Character(key.lowercased()) }) else { return nil }
        self = tool
    }

    /// Tools that leave a mark on the picture (Select and Crop only change what you see or keep).
    var draws: Bool { self != .select && self != .crop }
    /// Tools whose mark is dragged out between two corners.
    var isBox: Bool { self == .rectangle || self == .ellipse || self == .highlight || self == .blur }
    var isLine: Bool { self == .arrow || self == .line }

    var help: String { "\(label) (\(key.uppercased()))" }
}

// MARK: - Style

struct AnnotationColor: Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    static let red = AnnotationColor(red: 1.00, green: 0.23, blue: 0.19)
    static let orange = AnnotationColor(red: 1.00, green: 0.58, blue: 0.00)
    static let yellow = AnnotationColor(red: 1.00, green: 0.80, blue: 0.00)
    static let green = AnnotationColor(red: 0.20, green: 0.78, blue: 0.35)
    static let blue = AnnotationColor(red: 0.04, green: 0.52, blue: 1.00)
    static let purple = AnnotationColor(red: 0.69, green: 0.32, blue: 0.87)
    static let black = AnnotationColor(red: 0.08, green: 0.08, blue: 0.09)
    static let white = AnnotationColor(red: 1, green: 1, blue: 1)

    static let palette: [AnnotationColor] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Light colors get dark numbers and outlines so they stay readable.
    var isLight: Bool { 0.299 * red + 0.587 * green + 0.114 * blue > 0.62 }

    init(red: Double, green: Double, blue: Double) {
        (self.red, self.green, self.blue) = (red, green, blue)
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .red
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }
}

enum BlurStyle: String, CaseIterable, Identifiable {
    case blur = "Blur"
    case pixelate = "Pixelate"
    var id: String { rawValue }
}

/// Sizes are in "canvas points": the picture's longest side counts as 900 of them, so a 3 point line looks the same
/// on a small screenshot and on a 5K one. `AnnotateGeometry.unit` turns them into pixels.
struct AnnotationStyle: Equatable {
    var color = AnnotationColor.red
    /// 1 to 12.
    var width = 3.0
    var shadow = true
    /// Text size, 10 to 90.
    var textSize = 26.0
    var filled = false
    var blurStyle = BlurStyle.blur
    /// 1 to 8.
    var blurAmount = 4.0
}

// MARK: - Annotation

struct Annotation: Identifiable, Equatable {
    var id = UUID()
    /// Never `.select` or `.crop`.
    var kind: AnnotationTool
    /// Image pixels, origin at the top left. The corner a box or line begins at; a text's top left corner; a badge's center.
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text = ""
    var number = 1
    var style: AnnotationStyle

    var box: CGRect { AnnotateGeometry.rect(from: start, to: end) }
}

// MARK: - Geometry

enum AnnotateGeometry {
    /// Which part of an annotation is being dragged.
    enum Handle: Equatable, CaseIterable {
        case start, end
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    }

    /// Pixels per canvas point for a picture of this size.
    static func unit(for size: CGSize) -> CGFloat { max(0.6, max(size.width, size.height) / 900) }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func lineWidth(_ a: Annotation, unit: CGFloat) -> CGFloat { CGFloat(a.style.width) * unit }
    static func badgeRadius(_ a: Annotation, unit: CGFloat) -> CGFloat { (6 + CGFloat(a.style.width) * 2.5) * unit }
    static func font(_ a: Annotation, unit: CGFloat) -> NSFont { .systemFont(ofSize: CGFloat(a.style.textSize) * unit, weight: .semibold) }

    // MARK: Constraining

    /// Shift held: lines snap to 45° steps, boxes become squares.
    static func constrained(_ end: CGPoint, from start: CGPoint, for tool: AnnotationTool) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        if tool.isLine {
            let length = hypot(dx, dy)
            guard length > 0 else { return end }
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        }
        if tool.isBox || tool == .crop {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        return end
    }

    // MARK: Shapes

    struct ArrowShape {
        /// Where the shaft stops, just inside the head.
        var shaftEnd: CGPoint
        /// Tip, left wing, notch, right wing.
        var head: [CGPoint]
    }

    static func arrow(from a: CGPoint, to b: CGPoint, lineWidth lw: CGFloat, unit: CGFloat) -> ArrowShape {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0 else { return ArrowShape(shaftEnd: b, head: [b, b, b, b]) }
        let dir = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
        let normal = CGPoint(x: -dir.y, y: dir.x)
        let headLength = min(length * 0.7, 3.2 * lw + 7 * unit)
        let half = headLength * 0.5
        let base = CGPoint(x: b.x - dir.x * headLength, y: b.y - dir.y * headLength)
        let notch = CGPoint(x: b.x - dir.x * headLength * 0.74, y: b.y - dir.y * headLength * 0.74)
        let head = [b, CGPoint(x: base.x + normal.x * half, y: base.y + normal.y * half), notch,
                    CGPoint(x: base.x - normal.x * half, y: base.y - normal.y * half)]
        return ArrowShape(shaftEnd: CGPoint(x: b.x - dir.x * headLength * 0.8, y: b.y - dir.y * headLength * 0.8), head: head)
    }

    /// The text as drawn, so measuring and drawing agree.
    static func attributed(_ a: Annotation, unit: CGFloat) -> NSAttributedString {
        NSAttributedString(string: a.text, attributes: [.font: font(a, unit: unit), .foregroundColor: a.style.color.nsColor])
    }

    static func textSize(of a: Annotation, unit: CGFloat) -> CGSize {
        let measured = attributed(a, unit: unit).size()
        let font = font(a, unit: unit)
        // An empty text still gets room for the caret.
        return CGSize(width: max(measured.width, font.pointSize * 0.5), height: max(measured.height, font.boundingRectForFont.height))
    }

    // MARK: Bounds and hits

    /// Everything the annotation paints, in image pixels (shadow aside).
    static func bounds(of a: Annotation, unit: CGFloat) -> CGRect {
        let lw = lineWidth(a, unit: unit)
        switch a.kind {
        case .arrow:
            let head = 3.2 * lw + 7 * unit
            return a.box.insetBy(dx: -(lw / 2 + head / 2), dy: -(lw / 2 + head / 2))
        case .line:
            return a.box.insetBy(dx: -lw / 2, dy: -lw / 2)
        case .rectangle, .ellipse:
            return a.box.insetBy(dx: -lw / 2, dy: -lw / 2)
        case .highlight, .blur:
            return a.box
        case .text:
            return CGRect(origin: a.start, size: textSize(of: a, unit: unit))
        case .step:
            let r = badgeRadius(a, unit: unit)
            return CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        case .pen:
            guard let first = a.points.first else { return .null }
            let box = a.points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            return box.insetBy(dx: -lw / 2, dy: -lw / 2)
        case .select, .crop:
            return .null
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Whether `point` (image pixels) is on the annotation. `tolerance` is the slack, in pixels, a fingertip of precision needs.
    static func hit(_ a: Annotation, at point: CGPoint, tolerance: CGFloat, unit: CGFloat) -> Bool {
        let lw = lineWidth(a, unit: unit)
        switch a.kind {
        case .arrow, .line:
            return distance(from: point, toSegment: a.start, a.end) <= max(lw / 2, tolerance) + (a.kind == .arrow ? lw : 0)
        case .rectangle:
            let outer = a.box.insetBy(dx: -(lw / 2 + tolerance), dy: -(lw / 2 + tolerance))
            if a.style.filled { return outer.contains(point) }
            let inner = a.box.insetBy(dx: lw / 2 + tolerance, dy: lw / 2 + tolerance)
            return outer.contains(point) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(point))
        case .ellipse:
            let box = a.box
            guard box.width > 0, box.height > 0 else { return false }
            // How far out the point sits, measured in "radii" of the ellipse, then back to pixels.
            let nx = (point.x - box.midX) / (box.width / 2), ny = (point.y - box.midY) / (box.height / 2)
            let radial = hypot(nx, ny)
            let scale = min(box.width, box.height) / 2
            if a.style.filled { return (radial - 1) * scale <= lw / 2 + tolerance }
            return abs(radial - 1) * scale <= lw / 2 + tolerance
        case .highlight, .blur:
            return a.box.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .text:
            return bounds(of: a, unit: unit).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .step:
            let r = badgeRadius(a, unit: unit)
            return hypot(point.x - a.start.x, point.y - a.start.y) <= r + tolerance
        case .pen:
            guard a.points.count > 1 else { return a.points.first.map { hypot(point.x - $0.x, point.y - $0.y) <= max(lw / 2, tolerance) } ?? false }
            return zip(a.points, a.points.dropFirst()).contains { distance(from: point, toSegment: $0, $1) <= max(lw / 2, tolerance) }
        case .select, .crop:
            return false
        }
    }

    // MARK: Moving and resizing

    static func moved(_ a: Annotation, by d: CGSize) -> Annotation {
        var copy = a
        let shift = { (p: CGPoint) in CGPoint(x: p.x + d.width, y: p.y + d.height) }
        copy.start = shift(a.start)
        copy.end = shift(a.end)
        copy.points = a.points.map(shift)
        return copy
    }

    /// The handles an annotation offers: two ends for lines, eight around a box, none for the rest.
    static func handles(of a: Annotation) -> [(handle: Handle, point: CGPoint)] {
        switch a.kind {
        case .arrow, .line:
            return [(.start, a.start), (.end, a.end)]
        case .rectangle, .ellipse, .highlight, .blur:
            return handles(of: a.box)
        default:
            return []
        }
    }

    static func handles(of r: CGRect) -> [(handle: Handle, point: CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
         (.right, CGPoint(x: r.maxX, y: r.midY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    /// The handle under `point`, if any. `radius` is in pixels.
    static func handle(at point: CGPoint, in handles: [(handle: Handle, point: CGPoint)], radius: CGFloat) -> Handle? {
        handles.filter { hypot($0.point.x - point.x, $0.point.y - point.y) <= radius }
            .min { hypot($0.point.x - point.x, $0.point.y - point.y) < hypot($1.point.x - point.x, $1.point.y - point.y) }?.handle
    }

    /// `rect` with the dragged handle moved to `point`. Pulling past the opposite side flips the rectangle.
    static func resized(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var (left, right, top, bottom) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        switch handle {
        case .left, .topLeft, .bottomLeft: left = point.x
        case .right, .topRight, .bottomRight: right = point.x
        default: break
        }
        switch handle {
        case .top, .topLeft, .topRight: top = point.y
        case .bottom, .bottomLeft, .bottomRight: bottom = point.y
        default: break
        }
        return self.rect(from: CGPoint(x: left, y: top), to: CGPoint(x: right, y: bottom))
    }

    static func resized(_ a: Annotation, handle: Handle, to point: CGPoint, constrain: Bool = false) -> Annotation {
        var copy = a
        switch a.kind {
        case .arrow, .line:
            if handle == .start {
                copy.start = constrain ? constrained(point, from: a.end, for: a.kind) : point
            } else {
                copy.end = constrain ? constrained(point, from: a.start, for: a.kind) : point
            }
        case .rectangle, .ellipse, .highlight, .blur:
            let box = resized(a.box, handle: handle, to: point)
            copy.start = box.origin
            copy.end = CGPoint(x: box.maxX, y: box.maxY)
        default:
            break
        }
        return copy
    }

    /// Clamps a rectangle into `0...size`, keeping its size where it can.
    static func fitted(_ r: CGRect, in size: CGSize) -> CGRect {
        var r = r.standardized
        r.size.width = min(r.width, size.width)
        r.size.height = min(r.height, size.height)
        r.origin.x = min(max(r.minX, 0), size.width - r.width)
        r.origin.y = min(max(r.minY, 0), size.height - r.height)
        return r
    }
}

// MARK: - Blur cache

/// The whole picture blurred or pixelated once per strength, so every blur region just shows its part of it.
final class AnnotateBlurCache: @unchecked Sendable {
    private struct Key: Hashable {
        var style: BlurStyle
        var level: Int
    }

    private let lock = NSLock()
    private var base: ObjectIdentifier?
    private var images: [Key: CGImage] = [:]
    private static let context = CIContext()

    func image(for source: CGImage, style: BlurStyle, amount: Double, unit: CGFloat) -> CGImage? {
        let level = min(max(Int(amount.rounded()), 1), 8)
        let key = Key(style: style, level: level)
        lock.lock()
        defer { lock.unlock() }
        if base != ObjectIdentifier(source) {
            base = ObjectIdentifier(source)
            images = [:]
        }
        if let cached = images[key] { return cached }
        guard let made = Self.make(source, style: style, level: level, unit: unit) else { return nil }
        images[key] = made
        return made
    }

    /// Strength follows the picture's size (`unit`), so text is as unreadable on a 5K screenshot as on a small one.
    private static func make(_ source: CGImage, style: BlurStyle, level: Int, unit: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: source)
        let extent = input.extent
        let output: CIImage
        switch style {
        case .blur:
            output = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(unit) * 2.2 * Double(level)])
        case .pixelate:
            output = input.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                kCIInputScaleKey: Double(unit) * 3 * Double(level),
            ])
        }
        let space = source.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(output.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: space)
    }
}

// MARK: - Rendering

enum AnnotateRenderer {
    /// Draws the picture and its annotations into `ctx`, which must already map one image pixel to one unit with the origin
    /// at the top left and y pointing down. `scale` is how many device units an image pixel covers (shadows ignore the transform).
    /// `baseIsFlipped` says which way the context's untransformed space points: a view's does (y down), a bitmap's does not.
    static func draw(image: CGImage, annotations: [Annotation], blurs: AnnotateBlurCache, in ctx: CGContext, scale: CGFloat = 1,
                     baseIsFlipped: Bool = false, skipping: UUID? = nil) {
        let size = CGSize(width: image.width, height: image.height)
        let unit = AnnotateGeometry.unit(for: size)
        ctx.interpolationQuality = .high
        drawUpright(image, in: CGRect(origin: .zero, size: size), ctx)

        // Blur hides the picture, never the other annotations, so it goes first.
        for a in annotations where a.kind == .blur && a.id != skipping {
            drawBlur(a, source: image, blurs: blurs, unit: unit, ctx)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for a in annotations where a.kind != .blur && a.id != skipping {
            drawAnnotation(a, unit: unit, scale: scale, down: baseIsFlipped ? 1 : -1, ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// CGContext draws images y-up; this is the flip that makes them upright in a y-down context.
    private static func drawUpright(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func drawBlur(_ a: Annotation, source: CGImage, blurs: AnnotateBlurCache, unit: CGFloat, _ ctx: CGContext) {
        let box = a.box.integral
        guard box.width >= 2, box.height >= 2,
              let hidden = blurs.image(for: source, style: a.style.blurStyle, amount: a.style.blurAmount, unit: unit) else { return }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: min(2 * unit, box.width / 2), cornerHeight: min(2 * unit, box.height / 2), transform: nil))
        ctx.clip()
        drawUpright(hidden, in: CGRect(x: 0, y: 0, width: source.width, height: source.height), ctx)
        ctx.restoreGState()
    }

    private static func drawAnnotation(_ a: Annotation, unit: CGFloat, scale: CGFloat, down: CGFloat, _ ctx: CGContext) {
        let lw = AnnotateGeometry.lineWidth(a, unit: unit)
        let color = a.style.color.cgColor
        shadowed(a, unit: unit, scale: scale, down: down, ctx) {
            switch a.kind {
            case .arrow:
                let shape = AnnotateGeometry.arrow(from: a.start, to: a.end, lineWidth: lw, unit: unit)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(lw)
                ctx.setLineCap(.round)
                ctx.move(to: a.start)
                ctx.addLine(to: shape.shaftEnd)
                ctx.strokePath()
                ctx.setFillColor(color)
                ctx.addLines(between: shape.head)
                ctx.closePath()
                ctx.fillPath()
            case .line:
                ctx.setStrokeColor(color)
                ctx.setLineWidth(lw)
                ctx.setLineCap(.round)
                ctx.move(to: a.start)
                ctx.addLine(to: a.end)
                ctx.strokePath()
            case .rectangle:
                let radius = min(4 * unit, a.box.width / 2, a.box.height / 2)
                let path = CGPath(roundedRect: a.box, cornerWidth: radius, cornerHeight: radius, transform: nil)
                paint(path, filled: a.style.filled, color: color, lineWidth: lw, ctx)
            case .ellipse:
                paint(CGPath(ellipseIn: a.box, transform: nil), filled: a.style.filled, color: color, lineWidth: lw, ctx)
            case .highlight:
                let radius = min(3 * unit, a.box.width / 2, a.box.height / 2)
                ctx.setFillColor(a.style.color.nsColor.withAlphaComponent(0.4).cgColor)
                ctx.addPath(CGPath(roundedRect: a.box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            case .text:
                guard !a.text.isEmpty else { return }
                AnnotateGeometry.attributed(a, unit: unit).draw(at: a.start)
            case .step:
                drawBadge(a, unit: unit, ctx)
            case .pen:
                drawPen(a.points, lineWidth: lw, color: color, ctx)
            case .blur, .select, .crop:
                break
            }
        }
    }

    private static func paint(_ path: CGPath, filled: Bool, color: CGColor, lineWidth: CGFloat, _ ctx: CGContext) {
        ctx.addPath(path)
        if filled {
            ctx.setFillColor(color)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    private static func drawBadge(_ a: Annotation, unit: CGFloat, _ ctx: CGContext) {
        let r = AnnotateGeometry.badgeRadius(a, unit: unit)
        let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        let light = a.style.color.isLight
        ctx.setFillColor(a.style.color.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(light ? CGColor(gray: 0, alpha: 0.35) : CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(max(1.5 * unit, r * 0.12))
        ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
        let font = NSFont.systemFont(ofSize: r * (a.number >= 10 ? 1.0 : 1.15), weight: .bold)
        let label = NSAttributedString(string: "\(a.number)", attributes: [
            .font: font,
            .foregroundColor: light ? NSColor(white: 0.1, alpha: 1) : NSColor.white,
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2))
    }

    private static func drawPen(_ points: [CGPoint], lineWidth: CGFloat, color: CGColor, _ ctx: CGContext) {
        guard let first = points.first else { return }
        if points.count == 1 {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: first.x - lineWidth / 2, y: first.y - lineWidth / 2, width: lineWidth, height: lineWidth))
            return
        }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: first)
        // Curves through the midpoints, so a hand-drawn line has no corners.
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            ctx.addQuadCurve(to: mid, control: points[i])
        }
        ctx.addLine(to: points[points.count - 1])
        ctx.strokePath()
    }

    /// Draws `body` with a soft drop shadow under the whole mark (not under each part of it).
    private static func shadowed(_ a: Annotation, unit: CGFloat, scale: CGFloat, down: CGFloat, _ ctx: CGContext, _ body: () -> Void) {
        guard a.style.shadow, a.kind != .highlight else { return body() }
        ctx.saveGState()
        // The offset and blur are in the context's untransformed units, so they follow `scale` and `down`.
        ctx.setShadow(offset: CGSize(width: 0, height: down * 1.6 * unit * scale), blur: 5 * unit * scale, color: CGColor(gray: 0, alpha: 0.45))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: Output

    /// The finished picture: the image at `scale` times its size with every annotation drawn in.
    /// `opaque` flattens onto white, for formats that cannot hold transparency.
    static func render(image: CGImage, annotations: [Annotation], blurs: AnnotateBlurCache, scale: CGFloat = 1, opaque: Bool = false) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        // The picture's own color space keeps its colors exact; a few exotic ones can't be drawn into, so fall back to sRGB.
        guard let ctx = [own, sRGB].compactMap({ $0 }).lazy.compactMap({
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: $0, bitmapInfo: info)
        }).first else { return nil }
        if opaque {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / CGFloat(image.width), y: -CGFloat(height) / CGFloat(image.height))
        draw(image: image, annotations: annotations, blurs: blurs, in: ctx, scale: scale)
        return ctx.makeImage()
    }
}

// MARK: - Files

enum AnnotateFormat: String, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPEG"

    var id: String { rawValue }
    var ext: String { self == .png ? "png" : "jpg" }
    var type: UTType { self == .png ? .png : .jpeg }
}

enum AnnotateError: LocalizedError {
    case unreadable
    case encodeFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "macOS could not read that image."
        case .encodeFailed: "The image could not be put together."
        case .saveFailed: "The image could not be saved."
        }
    }
}

enum AnnotateScreenshot {
    /// The upright, full-size picture in `url` (the first frame of an animated one), or nil if macOS can't read it.
    static func load(_ url: URL) -> CGImage? {
        guard let reader = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return upright(image, orientation: FaceBlur.orientation(of: reader))
    }

    static func upright(_ image: CGImage, orientation: Int) -> CGImage? {
        try? ImageConverter.pixels(of: image, orientation: orientation, flattenAlpha: false).image
    }

    /// A picture from the pasteboard: an image file that was copied in Finder, or image data (a screenshot, a copied picture).
    static func image(from pasteboard: NSPasteboard) -> (image: CGImage, name: String?)? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        for url in urls {
            if let image = load(url) { return (image, url.deletingPathExtension().lastPathComponent) }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type), let reader = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(reader, 0, nil) else { continue }
            return (upright(image, orientation: FaceBlur.orientation(of: reader)) ?? image, nil)
        }
        return nil
    }

    static func encode(_ image: CGImage, as format: AnnotateFormat, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { throw AnnotateError.encodeFailed }
        var options: [CFString: Any] = [:]
        if format == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(writer, image, options as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw AnnotateError.encodeFailed }
        return data as Data
    }

    /// Writes the picture as a new file in `folder` and returns it. Never overwrites: a taken name gets a number.
    static func save(_ image: CGImage, name: String, format: AnnotateFormat, quality: Double, into folder: URL) throws -> URL {
        let data = try encode(image, as: format, quality: quality)
        let url = BatchFiles.uniqueURL(in: folder, name: name, ext: format.ext)
        do { try data.write(to: url, options: .atomic) } catch { throw AnnotateError.saveFailed }
        return url
    }

    /// "Screenshot 2026-10-28 at 14.30.05", the way macOS names its own.
    static func dateName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(f.string(from: date))"
    }
}
