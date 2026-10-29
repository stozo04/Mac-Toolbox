import AppKit
import XCTest
@testable import Toolbox

final class ColorPickerTests: XCTestCase {
    private let slate = RGBAColor(r: 110, g: 143, b: 158)   // #6E8F9E, the color in the design

    // MARK: Formats

    func testTheDesignColorInEveryFormat() {
        XCTAssertEqual(ColorFormat.hex.string(for: slate, includeAlpha: false), "#6E8F9E")
        XCTAssertEqual(ColorFormat.rgb.string(for: slate, includeAlpha: false), "rgb(110, 143, 158)")
        XCTAssertEqual(ColorFormat.hsl.string(for: slate, includeAlpha: false), "hsl(199, 20%, 53%)")
        XCTAssertEqual(ColorFormat.swiftUI.string(for: slate, includeAlpha: false), "Color(red: 0.431, green: 0.561, blue: 0.62)")
        XCTAssertEqual(ColorFormat.nsColor.string(for: slate, includeAlpha: false),
                       "NSColor(srgbRed: 0.431, green: 0.561, blue: 0.62, alpha: 1)")
        XCTAssertEqual(ColorFormat.uiColor.string(for: slate, includeAlpha: false),
                       "UIColor(red: 0.431, green: 0.561, blue: 0.62, alpha: 1)")
    }

    func testAlphaIsOnlyWrittenWhenIncluded() {
        let half = slate.withAlpha(0.5)
        XCTAssertEqual(ColorFormat.hex.string(for: half, includeAlpha: false), "#6E8F9E")
        XCTAssertEqual(ColorFormat.hex.string(for: half, includeAlpha: true), "#6E8F9E80")
        XCTAssertEqual(ColorFormat.rgb.string(for: half, includeAlpha: true), "rgba(110, 143, 158, 0.5)")
        XCTAssertEqual(ColorFormat.hsl.string(for: half, includeAlpha: true), "hsla(199, 20%, 53%, 0.5)")
        XCTAssertEqual(ColorFormat.swiftUI.string(for: half, includeAlpha: true), "Color(red: 0.431, green: 0.561, blue: 0.62, opacity: 0.5)")
        XCTAssertTrue(ColorFormat.nsColor.string(for: half, includeAlpha: true).hasSuffix("alpha: 0.5)"))
        XCTAssertTrue(ColorFormat.nsColor.string(for: half, includeAlpha: false).hasSuffix("alpha: 1)"))
        XCTAssertTrue(ColorFormat.oklch.string(for: half, includeAlpha: true).hasSuffix("/ 0.5)"))
        XCTAssertFalse(ColorFormat.oklch.string(for: half, includeAlpha: false).contains("/"))
    }

    func testEveryFormatHasATitleAndAnId() {
        XCTAssertEqual(ColorFormat.allCases.map(\.title), ["HEX", "RGB", "HSL", "OKLCH", "SwiftUI", "NSColor", "UIColor", "Tailwind"])
        XCTAssertEqual(Set(ColorFormat.allCases.map(\.id)).count, 8)
    }

    // MARK: Color spaces

    func testBlackWhiteAndGreysInHSL() {
        XCTAssertEqual(ColorFormat.hsl.string(for: .black, includeAlpha: false), "hsl(0, 0%, 0%)")
        XCTAssertEqual(ColorFormat.hsl.string(for: .white, includeAlpha: false), "hsl(0, 0%, 100%)")
        XCTAssertEqual(ColorFormat.hsl.string(for: RGBAColor(r: 255, g: 0, b: 0), includeAlpha: false), "hsl(0, 100%, 50%)")
        XCTAssertEqual(ColorFormat.hsl.string(for: RGBAColor(r: 0, g: 0, b: 255), includeAlpha: false), "hsl(240, 100%, 50%)")
    }

    func testHSLRoundTrips() {
        for color in [slate, RGBAColor(r: 200, g: 30, b: 90), RGBAColor(r: 12, g: 220, b: 40), RGBAColor(r: 255, g: 255, b: 0)] {
            let hsl = color.hsl
            let back = RGBAColor(hue: hsl.h, saturation: hsl.s, lightness: hsl.l)
            XCTAssertEqual(back.r255, color.r255)
            XCTAssertEqual(back.g255, color.g255)
            XCTAssertEqual(back.b255, color.b255)
        }
    }

    func testOKLCHMatchesKnownValues() {
        // White is lightness 1 with no chroma. Pure red is the standard reference: oklch(0.628 0.2577 29.23).
        let red = RGBAColor(r: 255, g: 0, b: 0).oklch
        XCTAssertEqual(red.l, 0.628, accuracy: 0.001)
        XCTAssertEqual(red.c, 0.2577, accuracy: 0.001)
        XCTAssertEqual(red.h, 29.23, accuracy: 0.1)
        let white = RGBAColor.white.oklch
        XCTAssertEqual(white.l, 1, accuracy: 0.001)
        XCTAssertEqual(white.c, 0, accuracy: 0.001)
        XCTAssertEqual(RGBAColor.black.oklch.l, 0, accuracy: 0.001)
        let blue = RGBAColor.parse("#3b82f6")!.oklch
        XCTAssertEqual(blue.l, 0.623, accuracy: 0.003)
        XCTAssertEqual(blue.c, 0.188, accuracy: 0.003)
        XCTAssertEqual(blue.h, 259.8, accuracy: 0.5)
    }

    func testGreysHaveNoHue() {
        XCTAssertEqual(RGBAColor(r: 128, g: 128, b: 128).oklch.h, 0)
        XCTAssertEqual(ColorFormat.oklch.string(for: .white, includeAlpha: false), "oklch(1 0 0)")
    }

    // MARK: Parsing

    func testParsesHexInEveryLength() {
        XCTAssertEqual(RGBAColor.parse("#6E8F9E"), slate)
        XCTAssertEqual(RGBAColor.parse("6e8f9e"), slate)
        XCTAssertEqual(RGBAColor.parse("  #6e8f9e\n"), slate)
        XCTAssertEqual(RGBAColor.parse("#fff"), .white)
        XCTAssertEqual(RGBAColor.parse("#f00")?.r255, 255)
        XCTAssertEqual(RGBAColor.parse("#6E8F9E80")?.a255, 128)
        XCTAssertEqual(RGBAColor.parse("#f008")?.a255, 136)
    }

    func testParsesRGBAndHSLText() {
        XCTAssertEqual(RGBAColor.parse("rgb(110, 143, 158)"), slate)
        XCTAssertEqual(RGBAColor.parse("rgb(110 143 158)"), slate)
        XCTAssertEqual(RGBAColor.parse("RGB(110,143,158)"), slate)
        XCTAssertEqual(RGBAColor.parse("rgba(110, 143, 158, 0.5)")?.a255, 128)
        XCTAssertEqual(RGBAColor.parse("rgb(110 143 158 / 50%)")?.a255, 128)
        XCTAssertEqual(RGBAColor.parse("rgb(100%, 0%, 0%)")?.r255, 255)
        let hsl = RGBAColor.parse("hsl(199, 20%, 53%)")!
        XCTAssertEqual(hsl.r255, 110, accuracy: 2)
        XCTAssertEqual(hsl.g255, 143, accuracy: 2)
        XCTAssertEqual(hsl.b255, 158, accuracy: 2)
        XCTAssertEqual(RGBAColor.parse("hsla(120 100% 50% / 0.25)")?.a255, 64)
    }

    func testRejectsTextThatIsNotAColor() {
        for text in ["", "   ", "#12", "#12345", "#gggggg", "rgb(1, 2)", "rgb(a, b, c)", "hsl(1)", "banana", "rgb(1,2,3", "lab(1 2 3)"] {
            XCTAssertNil(RGBAColor.parse(text), "\"\(text)\" is not a color")
        }
    }

    func testEveryFormatThatCanBeTypedReadsBackAsTheSameColor() {
        for color in [slate, RGBAColor(r: 3, g: 250, b: 77), RGBAColor.white] {
            for format in [ColorFormat.hex, .rgb, .hsl] {
                let text = format.string(for: color, includeAlpha: false)
                let back = RGBAColor.parse(text)
                XCTAssertNotNil(back, text)
                // HSL is written in whole numbers, so it can be a step off.
                XCTAssertEqual(back?.r255 ?? -9, color.r255, accuracy: format == .hsl ? 3 : 0, text)
                XCTAssertEqual(back?.g255 ?? -9, color.g255, accuracy: format == .hsl ? 3 : 0, text)
                XCTAssertEqual(back?.b255 ?? -9, color.b255, accuracy: format == .hsl ? 3 : 0, text)
            }
        }
    }

    func testPartsAreClamped() {
        let c = RGBAColor(red: 1.4, green: -0.2, blue: .nan, alpha: 7)
        XCTAssertEqual([c.red, c.green, c.blue, c.alpha], [1, 0, 0, 1])
    }

    func testCompositingOverABackdrop() {
        let red = RGBAColor(r: 255, g: 0, b: 0).withAlpha(0.5)
        let onWhite = red.composited(over: .white)
        XCTAssertEqual(onWhite.r255, 255)
        XCTAssertEqual(onWhite.g255, 128)
        XCTAssertEqual(onWhite.alpha, 1)
        XCTAssertEqual(RGBAColor.black.composited(over: .white), .black)
    }

    // MARK: Tailwind

    func testPaletteHasEveryNamedColor() {
        XCTAssertEqual(TailwindColors.all.count, 2 + 22 * 11)
        XCTAssertEqual(Set(TailwindColors.all.map(\.name)).count, TailwindColors.all.count)
    }

    func testExactTailwindColors() {
        let blue = TailwindColors.nearest(to: RGBAColor.parse("#3B82F6")!)
        XCTAssertEqual(blue.name, "blue-500")
        XCTAssertTrue(blue.isExact)
        XCTAssertEqual(TailwindColors.nearest(to: .white).name, "white")
        XCTAssertEqual(TailwindColors.nearest(to: .black).name, "black")
        XCTAssertEqual(TailwindColors.nearest(to: RGBAColor.parse("#EF4444")!).name, "red-500")
    }

    func testClosestTailwindColorForAnythingElse() {
        let near = TailwindColors.nearest(to: RGBAColor.parse("#3B83F5")!)
        XCTAssertEqual(near.name, "blue-500")
        XCTAssertFalse(near.isExact)
        XCTAssertEqual(near.hex, "#3B82F6")
        // Checked against a separate calculation of the distance to all 244 colors: cyan-600, then slate-500.
        XCTAssertEqual(TailwindColors.nearest(to: slate).name, "cyan-600")
    }

    func testTailwindFormatAddsOpacityLikeTailwindDoes() {
        let blue = RGBAColor.parse("#3B82F6")!
        XCTAssertEqual(ColorFormat.tailwind.string(for: blue, includeAlpha: false), "blue-500")
        XCTAssertEqual(ColorFormat.tailwind.string(for: blue.withAlpha(0.5), includeAlpha: true), "blue-500/50")
        XCTAssertEqual(ColorFormat.tailwind.string(for: blue.withAlpha(0.5), includeAlpha: false), "blue-500")
        XCTAssertEqual(ColorFormat.tailwind.string(for: blue, includeAlpha: true), "blue-500")
    }

    // MARK: Contrast

    func testBlackOnWhiteIsTheBestPossible() {
        let c = ColorContrast(text: .black, background: .white)
        XCTAssertEqual(c.ratio, 21, accuracy: 0.001)
        XCTAssertEqual(c.text, "21:1")
        XCTAssertTrue(c.aaNormal && c.aaLarge && c.aaaNormal && c.aaaLarge)
    }

    func testSameColorIsOneToOne() {
        let c = ColorContrast(text: slate, background: slate)
        XCTAssertEqual(c.ratio, 1, accuracy: 0.0001)
        XCTAssertFalse(c.aaLarge)
    }

    func testTheClassicGreyOnWhiteBoundary() {
        // #767676 is the lightest grey that passes AA for normal text on white; #777777 is just under.
        let pass = ColorContrast(text: RGBAColor.parse("#767676")!, background: .white)
        XCTAssertEqual(pass.ratio, 4.54, accuracy: 0.01)
        XCTAssertTrue(pass.aaNormal)
        XCTAssertFalse(pass.aaaNormal)
        XCTAssertTrue(pass.aaaLarge)
        let fail = ColorContrast(text: RGBAColor.parse("#777777")!, background: .white)
        XCTAssertEqual(fail.ratio, 4.48, accuracy: 0.01)
        XCTAssertFalse(fail.aaNormal)
        XCTAssertTrue(fail.aaLarge)
        XCTAssertFalse(fail.aaaLarge)
    }

    func testRatioIsTheSameEitherWayRound() {
        let a = RGBAColor.parse("#336699")!, b = RGBAColor.parse("#FFEECC")!
        XCTAssertEqual(ColorContrast(text: a, background: b).ratio, ColorContrast(text: b, background: a).ratio, accuracy: 1e-9)
    }

    func testRatioTextIsRoundedButNeverShowsAPassItDoesNotHave() {
        XCTAssertEqual(ColorContrast(text: .black, background: .white).text, "21:1")
        XCTAssertEqual(ColorContrast(text: RGBAColor.parse("#777777")!, background: .white).text, "4.48:1")
        XCTAssertEqual(ColorContrast(text: RGBAColor.parse("#767676")!, background: .white).text, "4.54:1")
        // 4.499 rounds to 4.50 but fails 4.5, so it is cut to 4.49; the same just under 3 and 7.
        XCTAssertEqual(ColorContrast(ratio: 4.499).text, "4.49:1")
        XCTAssertFalse(ColorContrast(ratio: 4.499).aaNormal)
        XCTAssertEqual(ColorContrast(ratio: 2.999).text, "2.99:1")
        XCTAssertEqual(ColorContrast(ratio: 6.9961).text, "6.99:1")
        XCTAssertEqual(ColorContrast(ratio: 4.5).text, "4.5:1")
        XCTAssertEqual(ColorContrast(ratio: 4.504).text, "4.5:1")
    }

    func testTranslucentTextIsJudgedAsItLooks() {
        // Black at 50% over white is a mid grey (#808080), well under black's 21:1.
        let c = ColorContrast(text: RGBAColor.black.withAlpha(0.5), background: .white)
        XCTAssertEqual(c.ratio, 3.95, accuracy: 0.05)
        XCTAssertFalse(c.aaNormal)
    }

    // MARK: History

    func testNewestColorGoesFirstAndRepeatsMoveUp() {
        var h = ColorHistory()
        h.add(.black); h.add(.white); h.add(slate)
        XCTAssertEqual(h.colors, [slate, .white, .black])
        h.add(.black)
        XCTAssertEqual(h.colors, [.black, slate, .white])
    }

    func testHistoryKeepsTheLastTwenty() {
        var h = ColorHistory()
        for i in 0..<30 { h.add(RGBAColor(r: i, g: 0, b: 0)) }
        XCTAssertEqual(h.colors.count, 20)
        XCTAssertEqual(h.colors.first?.r255, 29)
        XCTAssertEqual(h.colors.last?.r255, 10)
    }

    func testTwoPicksOfTheSamePixelAreOneEntry() {
        var h = ColorHistory()
        h.add(RGBAColor(red: 110.0 / 255, green: 143.0 / 255, blue: 158.0 / 255))
        h.add(RGBAColor(red: 110.2 / 255, green: 142.9 / 255, blue: 158.1 / 255))
        XCTAssertEqual(h.colors.count, 1)
    }

    func testHistoryIsSavedAndComesBackInOrder() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "color-picker-tests-\(UUID())"))
        var h = ColorHistory()
        h.add(.black); h.add(slate.withAlpha(0.5)); h.add(.white)
        h.save(to: defaults)
        XCTAssertEqual(ColorHistory.load(from: defaults).colors, h.colors)
        XCTAssertTrue(ColorHistory.load(from: UserDefaults(suiteName: "color-picker-empty-\(UUID())")!).colors.isEmpty)
    }

    // MARK: Palette

    private func image(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let o = (y * width + x) * 4
                // Premultiplied, as the context expects.
                data[o] = UInt8(Int(r) * Int(a) / 255); data[o + 1] = UInt8(Int(g) * Int(a) / 255)
                data[o + 2] = UInt8(Int(b) * Int(a) / 255); data[o + 3] = a
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testTwoColorImageGivesTwoColorsWithTheirShares() {
        let img = image(width: 100, height: 100) { x, _ in x < 75 ? (255, 0, 0, 255) : (0, 0, 255, 255) }
        let colors = PaletteExtractor.colors(in: img, count: 6)
        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(colors[0].color.r255, 255)
        XCTAssertEqual(colors[0].color.b255, 0)
        XCTAssertEqual(colors[0].share, 0.75, accuracy: 0.02)
        XCTAssertEqual(colors[1].color.b255, 255)
        XCTAssertEqual(colors[1].share, 0.25, accuracy: 0.02)
    }

    func testSixDistinctBandsAreAllFound() {
        let bands: [(UInt8, UInt8, UInt8)] = [(230, 30, 30), (240, 160, 20), (240, 230, 40), (30, 170, 60), (30, 90, 220), (140, 40, 190)]
        let img = image(width: 120, height: 60) { x, _ in
            let b = bands[x / 20]
            return (b.0, b.1, b.2, 255)
        }
        let colors = PaletteExtractor.colors(in: img, count: 6)
        XCTAssertEqual(colors.count, 6)
        for band in bands {
            let target = RGBAColor(r: Int(band.0), g: Int(band.1), b: Int(band.2))
            XCTAssertTrue(colors.contains { $0.color.distance(to: target) < 0.03 }, "missing \(band)")
        }
        XCTAssertEqual(colors.map(\.share).reduce(0, +), 1, accuracy: 0.001)
    }

    func testCountIsKeptBetweenFiveAndEight() {
        let img = image(width: 160, height: 160) { x, y in
            (UInt8(x * 255 / 159), UInt8(y * 255 / 159), UInt8((x + y) * 255 / 318), 255)
        }
        XCTAssertEqual(PaletteExtractor.colors(in: img, count: 2).count, 5)
        XCTAssertEqual(PaletteExtractor.colors(in: img, count: 5).count, 5)
        XCTAssertEqual(PaletteExtractor.colors(in: img, count: 50).count, 8)
        let eight = PaletteExtractor.colors(in: img, count: 8)
        XCTAssertEqual(eight.map(\.share), eight.map(\.share).sorted(by: >), "most common first")
    }

    func testNearTwinsAreMergedButNeverBelowFive() {
        // Two reds that look the same, plus four clearly different colors: the reds become one.
        let img = image(width: 120, height: 20) { x, _ in
            switch x / 20 {
            case 0: (200, 30, 30, 255)
            case 1: (202, 31, 29, 255)
            case 2: (30, 160, 60, 255)
            case 3: (30, 80, 210, 255)
            case 4: (240, 200, 30, 255)
            default: (120, 40, 170, 255)
            }
        }
        XCTAssertEqual(PaletteExtractor.colors(in: img, count: 6).count, 5)
    }

    func testSeeThroughPixelsAreIgnoredAndKeepTheirColor() {
        let img = image(width: 40, height: 40) { x, _ in x < 20 ? (0, 0, 0, 0) : (10, 200, 30, 255) }
        let colors = PaletteExtractor.colors(in: img, count: 6)
        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors[0].share, 1, accuracy: 0.001)
        XCTAssertEqual(colors[0].color.g255, 200, accuracy: 2)
        XCTAssertTrue(PaletteExtractor.colors(in: image(width: 8, height: 8) { _, _ in (0, 0, 0, 0) }, count: 6).isEmpty)
    }

    func testPaletteIsTheSameEveryTime() {
        let img = image(width: 90, height: 90) { x, y in (UInt8((x * 3) % 256), UInt8((y * 5) % 256), UInt8((x * y) % 256), 255) }
        XCTAssertEqual(PaletteExtractor.colors(in: img, count: 7), PaletteExtractor.colors(in: img, count: 7))
    }

    func testAnImageFileIsReadUpright() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("color-picker-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = image(width: 64, height: 32) { _, _ in (20, 120, 220, 255) }
        let url = dir.appendingPathComponent("blue.png")
        let rep = NSBitmapImageRep(cgImage: img)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        let sample = try XCTUnwrap(PaletteExtractor.sample(at: url))
        XCTAssertEqual(sample.width, 64)
        let colors = PaletteExtractor.colors(in: sample, count: 5)
        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors[0].color.b255, 220, accuracy: 2)
        XCTAssertNil(PaletteExtractor.sample(at: dir.appendingPathComponent("missing.png")))
    }

    // MARK: Model

    @MainActor private func makeModel() throws -> ColorPickerModel {
        ColorPickerModel(defaults: try XCTUnwrap(UserDefaults(suiteName: "color-picker-model-\(UUID())")))
    }

    @MainActor func testTypingAColorShowsItAndPutsItInHistory() throws {
        let model = try makeModel()
        XCTAssertNil(model.current)
        XCTAssertTrue(model.enter("#6E8F9E"))
        XCTAssertEqual(model.current, slate)
        XCTAssertEqual(model.history.colors, [slate])
        XCTAssertNil(model.inputError)
    }

    @MainActor func testTypingNonsenseSaysSoAndChangesNothing() throws {
        let model = try makeModel()
        model.enter("#6E8F9E")
        XCTAssertFalse(model.enter("purple-ish"))
        XCTAssertNotNil(model.inputError)
        XCTAssertEqual(model.current, slate)
        XCTAssertEqual(model.history.colors.count, 1)
    }

    @MainActor func testTypingATranslucentColorTurnsIncludeAlphaOn() throws {
        let model = try makeModel()
        XCTAssertFalse(model.includeAlpha)
        model.enter("#6E8F9E80")
        XCTAssertTrue(model.includeAlpha)
        XCTAssertEqual(model.current?.a255, 128)
    }

    @MainActor func testUsingAHistoryColorDoesNotReorderHistory() throws {
        let model = try makeModel()
        model.enter("#000000"); model.enter("#FFFFFF")
        model.use(.black)
        XCTAssertEqual(model.current, .black)
        XCTAssertEqual(model.history.colors, [.white, .black])
    }

    @MainActor func testHistorySurvivesARelaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "color-picker-relaunch-\(UUID())"))
        let first = ColorPickerModel(defaults: defaults)
        first.enter("#112233"); first.enter("#445566")
        let second = ColorPickerModel(defaults: defaults)
        XCTAssertEqual(second.history.colors, first.history.colors)
        XCTAssertEqual(second.current?.r255, 0x44)
        second.clearHistory()
        XCTAssertTrue(ColorPickerModel(defaults: defaults).history.colors.isEmpty)
    }

    @MainActor func testCopyPutsTheChosenFormatOnTheClipboard() throws {
        let model = try makeModel()
        model.enter("#6E8F9E")
        model.copy(.rgb)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "rgb(110, 143, 158)")
        XCTAssertEqual(model.copied, "rgb")
        model.includeAlpha = true
        model.setOpacity(0.5)
        model.copy(.hex)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "#6E8F9E80")
    }

    @MainActor func testContrastColorsAreFilledByTypingPickingOrHistory() throws {
        let model = try makeModel()
        model.mode = .contrast
        XCTAssertEqual(model.contrast.text, "21:1")
        model.enter("#777777", for: .text)
        XCTAssertEqual(model.textColor.r255, 0x77)
        XCTAssertEqual(model.activeSlot, .text)
        model.take(RGBAColor(r: 10, g: 20, b: 30), for: .background)
        XCTAssertEqual(model.backgroundColor, RGBAColor(r: 10, g: 20, b: 30))
        XCTAssertEqual(model.activeSlot, .background)
        model.take(.white)   // no slot named: goes to the one used last
        XCTAssertEqual(model.backgroundColor, .white)
        XCTAssertNil(model.current, "Contrast picks do not change the Pick tab's color")
        model.swapContrastColors()
        XCTAssertEqual(model.backgroundColor.r255, 0x77)
        XCTAssertEqual(model.textColor, .white)
    }

    @MainActor func testPickingWhileOnThePaletteTabGoesBackToPick() throws {
        let model = try makeModel()
        model.mode = .palette
        model.take(slate)
        XCTAssertEqual(model.mode, .pick)
        XCTAssertEqual(model.current, slate)
    }

    func testScreenColorsAreReadAsSRGBAndClamped() throws {
        let p3 = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)   // more red than sRGB can show
        let c = try XCTUnwrap(ColorPickerModel.color(from: p3))
        XCTAssertEqual(c.red, 1)
        XCTAssertGreaterThanOrEqual(c.green, 0)
        let plain = try XCTUnwrap(ColorPickerModel.color(from: NSColor(srgbRed: 110.0 / 255, green: 143.0 / 255, blue: 158.0 / 255, alpha: 1)))
        XCTAssertEqual(plain.quantized, slate)
    }

    @MainActor func testPaletteFromAnImageFileThenAChangedCount() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("color-picker-model-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = image(width: 100, height: 100) { x, y in (UInt8(x * 255 / 99), UInt8(y * 255 / 99), 128, 255) }
        let url = dir.appendingPathComponent("gradient.png")
        try XCTUnwrap(NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])).write(to: url)

        let model = try makeModel()
        model.loadPalette(from: [url])
        for _ in 0..<100 where model.paletteImage == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(model.paletteImage)
        XCTAssertEqual(model.paletteName, "gradient.png")
        XCTAssertEqual(model.palette.count, 6)
        model.paletteCount = 8
        XCTAssertEqual(model.palette.count, 8)
        XCTAssertEqual(model.paletteText.split(separator: "\n").count, 8)
        XCTAssertTrue(model.paletteText.split(separator: "\n").allSatisfy { $0.hasPrefix("#") && $0.count == 7 })
        model.clearPalette()
        XCTAssertNil(model.paletteImage)
        XCTAssertTrue(model.palette.isEmpty)
    }

    @MainActor func testAFileThatIsNotAnImageIsRefused() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("color-picker-text-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        let model = try makeModel()
        model.loadPalette(from: [url])
        XCTAssertNil(model.paletteImage)
        XCTAssertNotNil(model.paletteNotice)
    }
}
