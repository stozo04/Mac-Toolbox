import SwiftUI

struct ColorPickerView: View {
    @State private var model = ColorPickerModel.shared
    @State private var typed = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            main.frame(maxWidth: .infinity, maxHeight: .infinity)
            options.frame(width: 240)
        }
        // Command-Shift-C starts a pick on every tab. It lives in a button that is not drawn.
        .background {
            Button("Pick Color from Screen") { model.pickFromScreen() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    // MARK: Main card

    private var main: some View {
        VStack(spacing: 14) {
            Picker("", selection: $model.mode) {
                ForEach(ColorPickerModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            switch model.mode {
            case .pick: PickPane(model: model)
            case .palette: PalettePane(model: model)
            case .contrast: ContrastPane(model: model)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cardBackground(corner: 24)
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options").font(.headline)
            switch model.mode {
            case .pick: pickOptions
            case .palette: paletteOptions
            case .contrast: contrastOptions
            }
            Spacer()
            Label("Reads the screen with the macOS color sampler. No screen recording permission, nothing leaves this Mac.",
                  systemImage: "lock.fill").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    @ViewBuilder private var pickOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Include alpha", isOn: $model.includeAlpha)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Opacity").font(.callout)
                    Spacer()
                    Text("\(Int(((model.current?.alpha ?? 1) * 100).rounded()))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { model.current?.alpha ?? 1 }, set: { model.setOpacity($0) }), in: 0...1)
                    .controlSize(.small)
            }
            .disabled(!model.includeAlpha || model.current == nil)
        }
        .padding(12)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        VStack(alignment: .leading, spacing: 6) {
            Text("Type a color").font(.callout)
            TextField("#6E8F9E", text: $typed)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .onSubmit { if model.enter(typed) { typed = "" } }
            if let error = model.inputError {
                Text(error).font(.caption2).foregroundStyle(.red)
            } else {
                Text("HEX, rgb() or hsl(), then Return. Add it with opacity (#RRGGBBAA, rgba()) for a see-through color.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        Text("Pick from anywhere with ⇧⌘C. Press Esc to cancel.").font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder private var paletteOptions: some View {
        HStack {
            Text("Colors").font(.callout)
            Spacer()
            Stepper("\(model.paletteCount)", value: $model.paletteCount, in: PaletteExtractor.countRange).monospacedDigit()
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        Text("The main colors are found by grouping similar pixels. A flat image can have fewer than you ask for.")
            .font(.caption2).foregroundStyle(.secondary)
        if model.paletteImage != nil {
            Button("Choose Another Image") { model.clearPalette() }
        }
    }

    @ViewBuilder private var contrastOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WCAG 2 levels").font(.callout)
            threshold("AA", "Normal text", "4.5")
            threshold("AA", "Large text", "3")
            threshold("AAA", "Normal text", "7")
            threshold("AAA", "Large text", "4.5")
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        Text("Large text is 18 pt or bigger, or 14 pt bold. Pick a color for a box with Pick Color or ⇧⌘C; it fills the box you used last.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func threshold(_ level: String, _ title: String, _ need: String) -> some View {
        HStack {
            Text(level).font(.caption).bold().frame(width: 34, alignment: .leading)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(need):1").font(.caption).monospacedDigit()
        }
    }
}

// MARK: - Pick

private struct PickPane: View {
    let model: ColorPickerModel

    var body: some View {
        if let color = model.current {
            ScrollView {
                VStack(spacing: 14) {
                    header(color)
                    // The short values sit two to a row; the code snippets are long, so each gets a whole row.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(ColorFormat.allCases.filter { !$0.isCode }) { formatRow($0, color) }
                    }
                    VStack(spacing: 8) {
                        ForEach(ColorFormat.allCases.filter(\.isCode)) { formatRow($0, color) }
                    }
                    HistoryStrip(model: model)
                }
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "eyedropper").font(.system(size: 30))
                    .frame(width: 60, height: 60)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("Pick a color from anywhere on screen").font(.headline)
                Text("Click any pixel in any app. Press Esc to cancel.").font(.caption).foregroundStyle(.secondary)
                pickButton
                if !model.history.colors.isEmpty { HistoryStrip(model: model).padding(.top, 8) }
                Spacer()
            }
        }
    }

    private func header(_ color: RGBAColor) -> some View {
        let shown = model.includeAlpha ? color : color.opaque
        return HStack(spacing: 14) {
            ColorSwatch(color: shown).frame(width: 150, height: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text(ColorFormat.hex.string(for: color, includeAlpha: model.includeAlpha))
                    .font(.system(size: 26, weight: .bold, design: .monospaced)).textSelection(.enabled)
                Text(ColorFormat.rgb.string(for: color, includeAlpha: model.includeAlpha))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if model.copied != nil { CopiedPill(text: "Copied") }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            pickButton
        }
        .padding(14)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var pickButton: some View {
        Button { model.pickFromScreen() } label: {
            Label("Pick Color from Screen", systemImage: "eyedropper")
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(model.isPicking)
        .help("Command-Shift-C")
    }

    private func formatRow(_ format: ColorFormat, _ color: RGBAColor) -> some View {
        let value = format.string(for: color, includeAlpha: model.includeAlpha)
        let justCopied = model.copied == format.rawValue
        return Button { model.copy(format) } label: {
            HStack(spacing: 8) {
                Text(format.title).font(.caption).bold().foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(value).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    if format == .tailwind { tailwindNote(color) }
                }
                Spacer(minLength: 4)
                if justCopied { CopiedPill(text: "Copied") } else {
                    Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Copy \(format.title)")
        .accessibilityLabel("Copy \(format.title): \(value)")
    }

    private func tailwindNote(_ color: RGBAColor) -> some View {
        let match = TailwindColors.nearest(to: color)
        return Text(match.isExact ? "Exact match \(match.hex)" : "Closest match \(match.hex)")
            .font(.caption2).foregroundStyle(.secondary)
    }
}

private struct HistoryStrip: View {
    let model: ColorPickerModel

    var body: some View {
        if !model.history.colors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("History").font(.callout).bold()
                    Text("last \(ColorHistory.limit)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.clearHistory() }.buttonStyle(.link).font(.caption)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 30), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(model.history.colors, id: \.self) { color in
                        Button { model.use(color) } label: {
                            ColorSwatch(color: color.opaque, corner: 8).frame(width: 30, height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Theme.accent, lineWidth: model.current == color ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .help(ColorFormat.hex.string(for: color, includeAlpha: color.alpha < 1))
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

// MARK: - Palette from Image

private struct PalettePane: View {
    let model: ColorPickerModel
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let image = model.paletteImage {
                result(image)
            } else {
                VStack(spacing: 10) {
                    if model.isReadingImage {
                        ProgressView().controlSize(.small)
                    } else {
                        DropZone(title: "Drop an Image Here", hint: "Get its 5 to 8 main colors.", symbol: "photo",
                                 allowsMultiple: false, button: "Choose Image...") { model.loadPalette(from: $0) }
                    }
                    if let notice = model.paletteNotice {
                        Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
                    }
                    Button("Paste Image") { model.pastePaletteImage() }.keyboardShortcut("v", modifiers: .command)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.loadPalette(from: [url]) } }
                }
            }
            return true
        }
    }

    private func result(_ image: CGImage) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(model.paletteName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            VStack(spacing: 10) {
                bar
                ScrollView {
                    VStack(spacing: 6) { ForEach(model.palette) { row($0) } }
                }
                HStack {
                    Button("Paste Image") { model.pastePaletteImage() }.keyboardShortcut("v", modifiers: .command)
                    Spacer()
                    if model.copied == "palette" { CopiedPill(text: "Copied") }
                    Button("Copy All HEX") { model.copy(model.paletteText, key: "palette") }.disabled(model.palette.isEmpty)
                }
            }
            .frame(width: 270)
        }
    }

    /// The colors side by side, each as wide as its share of the image.
    private var bar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(model.palette) { item in
                    ColorSwatch(color: item.color, corner: 0).frame(width: max(2, geo.size.width * item.share))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(height: 34)
    }

    private func row(_ item: PaletteColor) -> some View {
        let hex = ColorFormat.hex.string(for: item.color, includeAlpha: false)
        return HStack(spacing: 10) {
            ColorSwatch(color: item.color, corner: 8).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(hex).font(.system(.callout, design: .monospaced))
                Text("\(Int((item.share * 100).rounded()))% of the image").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.copied == hex { CopiedPill(text: "Copied") }
            Button { model.take(item.color) } label: { Image(systemName: "eyedropper") }
                .buttonStyle(.borderless).help("Show in Pick")
        }
        .padding(8)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { model.copy(hex, key: hex) }
        .help("Copy \(hex)")
    }
}

// MARK: - Contrast

private struct ContrastPane: View {
    let model: ColorPickerModel

    var body: some View {
        let result = model.contrast
        ScrollView {
            VStack(spacing: 14) {
                preview(result)
                HStack(spacing: 10) {
                    badge("AA", "Normal text", result.aaNormal)
                    badge("AA", "Large text", result.aaLarge)
                    badge("AAA", "Normal text", result.aaaNormal)
                    badge("AAA", "Large text", result.aaaLarge)
                }
                HStack(alignment: .top, spacing: 10) {
                    ContrastSlot(model: model, slot: .text, title: "Text", color: model.textColor)
                    Button { model.swapContrastColors() } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonStyle(.bordered).help("Swap text and background").padding(.top, 30)
                    ContrastSlot(model: model, slot: .background, title: "Background", color: model.backgroundColor)
                }
            }
        }
    }

    private func preview(_ result: ColorContrast) -> some View {
        let background = model.backgroundColor, text = model.textColor
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Large text sample").font(.system(size: 26, weight: .bold))
                Text("The quick brown fox jumps over the lazy dog. Normal text at 14 points.").font(.system(size: 14))
            }
            .foregroundStyle(text.swiftUI)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(result.text).font(.system(size: 30, weight: .bold, design: .monospaced))
                Text("contrast ratio").font(.caption)
            }
            .foregroundStyle(text.swiftUI)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Checkerboard()
                background.swiftUI
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func badge(_ level: String, _ title: String, _ pass: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2).foregroundStyle(pass ? Color.green : Color.red)
            Text(level).font(.callout).bold()
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(pass ? "Pass" : "Fail").font(.caption2).bold().foregroundStyle(pass ? Color.green : Color.red)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(level) \(title): \(pass ? "pass" : "fail")")
    }
}

/// One of the two colors Contrast compares: a swatch, a field to type it in, and ways to fill it.
private struct ContrastSlot: View {
    let model: ColorPickerModel
    let slot: ColorPickerModel.Slot
    let title: String
    let color: RGBAColor
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isActive: Bool { model.activeSlot == slot }
    private var hex: String { ColorFormat.hex.string(for: color, includeAlpha: color.alpha < 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).bold()
            HStack(spacing: 8) {
                ColorSwatch(color: color, corner: 8).frame(width: 36, height: 36)
                TextField("#000000", text: $draft)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .focused($focused)
                    .onSubmit { if !model.enter(draft, for: slot) { draft = hex } }
            }
            HStack {
                Button { model.pickFromScreen(for: slot) } label: { Label("Pick", systemImage: "eyedropper") }
                    .disabled(model.isPicking)
                Menu {
                    if model.history.colors.isEmpty { Text("No colors yet") }
                    ForEach(model.history.colors, id: \.self) { entry in
                        Button { model.use(entry, for: slot) } label: {
                            let name = ColorFormat.hex.string(for: entry, includeAlpha: entry.alpha < 1)
                            Label { Text(name) } icon: { Image(nsImage: swatchImage(entry)) }
                        }
                    }
                } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .menuStyle(.button).fixedSize()
            }
            .controlSize(.small)
            if let error = model.inputError, focused {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent, lineWidth: isActive ? 1.5 : 0))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { model.activeSlot = slot }
        .onAppear { draft = hex }
        .onChange(of: color) { draft = hex }
        .onChange(of: focused) { if focused { model.activeSlot = slot } }
    }

    private func swatchImage(_ color: RGBAColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Pieces

extension RGBAColor {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// A color chip. A see-through color is drawn over a checkerboard so the opacity is visible.
struct ColorSwatch: View {
    let color: RGBAColor
    var corner: CGFloat = 14

    var body: some View {
        ZStack {
            if color.alpha < 1 { Checkerboard() }
            color.swiftUI
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Theme.stroke))
        .accessibilityLabel(ColorFormat.hex.string(for: color, includeAlpha: color.alpha < 1))
    }
}

/// The orange "Copied" pill from the design.
private struct CopiedPill: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.orange, in: Capsule())
            .transition(.opacity)
    }
}
