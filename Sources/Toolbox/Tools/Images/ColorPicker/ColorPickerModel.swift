import AppKit
import Observation

@MainActor @Observable
final class ColorPickerModel {
    /// Shared so the picked colors survive switching to another tool and back.
    static let shared = ColorPickerModel()

    enum Mode: String, CaseIterable, Identifiable {
        case pick = "Pick", palette = "Palette from Image", contrast = "Contrast"
        var id: String { rawValue }
    }

    /// The two colors Contrast compares.
    enum Slot { case text, background }

    var mode = Mode.pick
    /// The color shown in Pick mode.
    private(set) var current: RGBAColor?
    /// Adds the opacity to every copied format (#RRGGBBAA, rgba(), ...).
    var includeAlpha = false
    private(set) var history: ColorHistory
    /// What was just copied (a format's raw value, a hex code or "palette"), for the "Copied" pill.
    private(set) var copied: String?
    /// Set when the text field holds something that is not a color.
    private(set) var inputError: String?

    // Contrast
    private(set) var textColor = RGBAColor.black
    private(set) var backgroundColor = RGBAColor.white
    /// The color Command-Shift-C fills while on the Contrast tab.
    var activeSlot = Slot.text

    // Palette
    private(set) var paletteImage: CGImage?
    private(set) var paletteName: String?
    private(set) var palette: [PaletteColor] = []
    var paletteCount = 6 { didSet { if paletteCount != oldValue { refreshPalette() } } }
    private(set) var isReadingImage = false
    private(set) var paletteNotice: String?

    private var sampler: NSColorSampler?
    private var copiedTask: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = ColorHistory.load(from: defaults)
        current = history.colors.first
    }

    var contrast: ColorContrast { ColorContrast(text: textColor, background: backgroundColor) }
    var isPicking: Bool { sampler != nil }

    // MARK: Picking

    /// Opens the macOS magnifier. Click a pixel to take it, Esc to cancel. Needs no screen recording permission.
    func pickFromScreen(for slot: Slot? = nil) {
        guard sampler == nil else { return }
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { picked in
            let color = picked.flatMap(Self.color(from:))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sampler = nil
                if let color { self.take(color, for: slot) }
            }
        }
    }

    /// The pick routed to where it belongs: the Contrast slot that was asked for, or the main color.
    func take(_ color: RGBAColor, for slot: Slot? = nil) {
        let color = color.quantized
        history.add(color)
        history.save(to: defaults)
        inputError = nil
        if mode == .contrast {
            set(color, for: slot ?? activeSlot)
        } else {
            current = color
            if mode == .palette { mode = .pick }
        }
    }

    func set(_ color: RGBAColor, for slot: Slot) {
        activeSlot = slot
        switch slot {
        case .text: textColor = color
        case .background: backgroundColor = color
        }
    }

    /// Shows a color from History without adding it again.
    func use(_ color: RGBAColor, for slot: Slot? = nil) {
        inputError = nil
        if mode == .contrast {
            set(color, for: slot ?? activeSlot)
        } else {
            current = color
        }
    }

    /// Reads a typed color. Returns false (and says why in `inputError`) when it is not one.
    @discardableResult
    func enter(_ text: String, for slot: Slot? = nil) -> Bool {
        guard let color = RGBAColor.parse(text) else {
            inputError = "Not a color. Try #6E8F9E, rgb(110, 143, 158) or hsl(200, 18%, 53%)."
            return false
        }
        // A typed color with opacity turns on Include alpha, so the opacity is not dropped on copy.
        if color.alpha < 1, mode != .contrast { includeAlpha = true }
        take(color, for: slot)
        return true
    }

    func setOpacity(_ alpha: Double) {
        guard let current else { return }
        self.current = current.withAlpha(alpha)
    }

    func swapContrastColors() {
        (textColor, backgroundColor) = (backgroundColor, textColor)
    }

    func clearHistory() {
        history.clear()
        history.save(to: defaults)
    }

    /// An `NSColor` from the screen, in sRGB. Wide-gamut screens can give values just outside 0...1; those are clamped.
    nonisolated static func color(from picked: NSColor) -> RGBAColor? {
        guard let c = picked.usingColorSpace(.sRGB) else { return nil }
        return RGBAColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }

    // MARK: Copying

    func copy(_ format: ColorFormat) {
        guard let current else { return }
        copy(format.string(for: current, includeAlpha: includeAlpha), key: format.rawValue)
    }

    /// Copies any text and shows the "Copied" pill next to whatever `key` names.
    func copy(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = key
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { self?.copied = nil }
        }
    }

    // MARK: Palette

    func loadPalette(from urls: [URL]) {
        guard let url = urls.compactMap({ BatchFiles.images(in: $0).first }).first else {
            paletteNotice = "That is not an image."
            return
        }
        paletteNotice = nil
        isReadingImage = true
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { PaletteExtractor.sample(at: url) }.value
            guard let self else { return }
            self.isReadingImage = false
            guard let image else {
                self.paletteNotice = "\(url.lastPathComponent) could not be read."
                Log.warning("Palette image could not be read", category: "color-picker", Log.fileFacts(url))
                return
            }
            self.setPaletteImage(image, name: url.lastPathComponent)
        }
    }

    /// Uses an image copied to the clipboard (a screenshot, an image copied from a browser).
    func pastePaletteImage() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { !BatchFiles.images(in: $0).isEmpty }) {
            loadPalette(from: urls)
            return
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            paletteNotice = "There is no image on the clipboard."
            return
        }
        paletteNotice = nil
        setPaletteImage(cg, name: "Pasted image")
    }

    func clearPalette() {
        paletteImage = nil
        paletteName = nil
        palette = []
        paletteNotice = nil
    }

    private func setPaletteImage(_ image: CGImage, name: String) {
        paletteImage = image
        paletteName = name
        refreshPalette()
        if palette.isEmpty { paletteNotice = "No solid colors found in this image." }
    }

    private func refreshPalette() {
        guard let paletteImage else { return }
        palette = PaletteExtractor.colors(in: paletteImage, count: paletteCount)
    }

    /// Hex codes, one per line.
    var paletteText: String {
        palette.map { ColorFormat.hex.string(for: $0.color, includeAlpha: false) }.joined(separator: "\n")
    }
}
