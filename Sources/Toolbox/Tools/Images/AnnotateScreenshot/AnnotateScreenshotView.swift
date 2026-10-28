import SwiftUI
import UniformTypeIdentifiers

struct AnnotateScreenshotView: View {
    @State private var model = AnnotateScreenshotModel.shared
    @State private var thumbnail: CGImage?
    @State private var monitor: Any?
    @State private var targeted = false
    @State private var confirmClose = false

    var body: some View {
        Group {
            if model.hasDocument { editor } else { empty }
        }
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
    }

    // MARK: Empty state

    private var empty: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(targeted ? Theme.accent : Theme.tint.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    )
                VStack(spacing: 10) {
                    Image(systemName: "pencil.and.outline").font(.system(size: 26))
                        .frame(width: 54, height: 54)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("Drop a Screenshot Here").font(.headline)
                    Text("Or press ⌘V to paste one, or capture part of your screen.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Choose File...") { chooseFile() }
                        Button { model.capture() } label: { Label("Capture Area", systemImage: "viewfinder") }
                            .disabled(model.isCapturing)
                    }
                    if let notice = model.notice {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.yellow).multilineTextAlignment(.center).frame(maxWidth: 340)
                    }
                    Label("Processed on this Mac. Originals stay untouched.", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted, perform: drop)
            shortcuts.frame(width: 240)
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools").font(.headline)
            Text("Pick one from the toolbar, or press its key.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(AnnotationTool.allCases.enumerated()), id: \.element) { index, tool in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        Image(systemName: tool.symbol).frame(width: 20).foregroundStyle(.secondary)
                        Text(tool.label).font(.callout)
                        Spacer()
                        Text(String(tool.key).uppercased())
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .frame(width: 22, height: 20)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .frame(height: 32)
                }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    // MARK: Editor

    private var editor: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                toolbar
                canvas
            }
            inspector.frame(width: 240)
        }
        .task(id: model.revision) { await renderThumbnail() }
        .confirmationDialog("Close this image?", isPresented: $confirmClose) {
            Button("Close Without Saving", role: .destructive) { model.close() }
        } message: {
            Text("Your marks on it will be lost unless you saved or copied the image.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                IconButton(symbol: tool.symbol, help: tool.help, selected: model.tool == tool) { model.setTool(tool) }
                if tool == .select || tool == .crop { toolbarDivider }
            }
            Spacer(minLength: 8)
            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: model.canUndo) { model.undo() }
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: model.canRedo) { model.redo() }
            toolbarDivider
            IconButton(symbol: "trash", help: "Delete (⌫)", enabled: model.selected != nil) { model.deleteSelected() }
        }
        .padding(6)
        .cardBackground(corner: 16)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 18).padding(.horizontal, 5)
    }

    private var canvas: some View {
        ZStack {
            AnnotateCanvas(model: model, revision: model.revision)
            if model.isCapturing {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.inset)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.stroke))
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.tool == .crop { cropSection } else { styleSection }
                Divider()
                imageSection
                Divider()
                exportSection
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(corner: 24)
    }

    /// What the controls apply to: the selected mark, or else the tool.
    private var focus: AnnotationTool { model.selected?.kind ?? model.tool }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.selected == nil ? focus == .select ? "Style" : focus.label : "Selected \(focus.label)").font(.headline)
                Spacer()
            }
            if focus == .select {
                Text("Click a mark to move it or change how it looks.").font(.caption).foregroundStyle(.secondary)
            } else {
                if focus != .blur { colorControls }
                VStack(spacing: 0) {
                    if [.arrow, .line, .rectangle, .ellipse, .pen, .step].contains(focus) {
                        sliderRow(focus == .step ? "Size" : "Width", value: styleBinding(\.width), range: 1...12, label: "\(Int(model.style.width))")
                    }
                    if focus == .text {
                        sliderRow("Text size", value: styleBinding(\.textSize), range: 10...90, label: "\(Int(model.style.textSize))")
                    }
                    if focus == .blur {
                        row("Effect") {
                            Picker("", selection: styleBinding(\.blurStyle)) {
                                ForEach(BlurStyle.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                        }
                        sliderRow("Amount", value: styleBinding(\.blurAmount), range: 1...8, label: "\(Int(model.style.blurAmount))")
                    }
                    if focus == .rectangle || focus == .ellipse {
                        row("Fill") { Toggle("", isOn: styleBinding(\.filled)).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                    }
                    if ![.highlight, .blur].contains(focus) {
                        row("Shadow") { Toggle("", isOn: styleBinding(\.shadow)).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                    }
                }
                .padding(.horizontal, 10)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if focus == .blur {
                    Text("Blur hides the screenshot underneath, never your other marks.").font(.caption2).foregroundStyle(.secondary)
                }
                if focus == .text {
                    Text(model.editingID == nil ? "Click the picture to type. Press Return to finish." : "Press Return to finish, Shift-Return for a new line.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if focus == .step {
                    Text("Each click adds the next number.").font(.caption2).foregroundStyle(.secondary)
                }
                if focus.isLine || focus.isBox {
                    Text("Hold Shift to keep it straight or square.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if model.selected != nil { selectionActions }
        }
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(AnnotationColor.palette, id: \.self) { swatch in
                    Button { model.restyle { $0.color = swatch } } label: {
                        Circle().fill(swatch.color)
                            .overlay(Circle().strokeBorder(Theme.tint.opacity(0.25), lineWidth: 1))
                            .frame(width: 20, height: 20)
                            .padding(2)
                            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: model.style.color == swatch ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(swatch == .red ? "Red" : "")
                }
            }
            HStack {
                Text("Color").font(.callout)
                Spacer()
                ColorPicker("", selection: Binding(get: { model.style.color.color }, set: { c in model.restyle { $0.color = AnnotationColor(c) } }),
                            supportsOpacity: false).labelsHidden()
            }
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "plus.square.on.square", help: "Duplicate (⌘D)", bordered: true) { model.duplicateSelected() }
            IconButton(symbol: "square.3.layers.3d.top.filled", help: "Bring to Front", bordered: true) { model.bringToFront() }
            IconButton(symbol: "square.3.layers.3d.bottom.filled", help: "Send to Back", bordered: true) { model.sendToBack() }
            IconButton(symbol: "trash", help: "Delete (⌫)", bordered: true) { model.deleteSelected() }
        }
    }

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crop").font(.headline)
            Text("Drag the edges or corners to choose what to keep. Your marks move with the picture.").font(.caption).foregroundStyle(.secondary)
            if let crop = model.cropRect {
                Text("\(Int(crop.width.rounded())) × \(Int(crop.height.rounded())) px").font(.callout).monospacedDigit()
            }
            HStack {
                Button("Cancel") { model.cancelCrop() }
                Button("Apply Crop") { model.applyCrop() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.cropChanged)
            }
            Text("Press Return to apply, Esc to cancel.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Image and export

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Image").font(.headline)
                Spacer()
                Text("\(Int(model.pixelSize.width)) × \(Int(model.pixelSize.height))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("Open…") { chooseFile() }
                Button { model.capture() } label: { Label("Capture", systemImage: "viewfinder") }
                    .disabled(model.isCapturing)
                    .help("Select part of the screen to annotate")
                Spacer(minLength: 0)
                Button { confirmClose = true } label: { Image(systemName: "xmark") }
                    .help("Close image")
            }
            .controlSize(.small)
            Text("Press ⌘V to paste another picture.").font(.caption2).foregroundStyle(.secondary)
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export").font(.headline)
            HStack {
                Text("Format").font(.callout)
                Spacer()
                Picker("", selection: $model.format) {
                    ForEach(AnnotateFormat.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            if model.format == .jpeg {
                HStack(spacing: 6) {
                    Text("Quality").font(.callout)
                    Spacer()
                    Slider(value: $model.jpegQuality, in: 0.5...1).frame(width: 90)
                    Text("\(Int(model.jpegQuality * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
            }
            HStack {
                Button { model.copy() } label: {
                    Label(model.copied ? "Copied" : "Copy", systemImage: model.copied ? "checkmark" : "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("Copy the full-size image (⌘C)")
                Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                    .help("Save a new \(model.format.rawValue) in Downloads (⌘S)")
            }
            if let url = model.savedURL {
                HStack(spacing: 6) {
                    Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    Spacer()
                    RevealButton { model.reveal(url) }
                }
            }
            thumbnailView
        }
    }

    private var thumbnailView: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.inset)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit().padding(6)
                        .onDrag { dragProvider() }
                        .help("Drag into a chat or an email")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 110)
            Label("Drag this into any app", systemImage: "hand.draw").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func row<Content: View>(_ title: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack { Text(title).font(.callout).fixedSize(); Spacer(minLength: 4); control() }.frame(height: 38)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.callout).fixedSize()
            Spacer(minLength: 4)
            Slider(value: value, in: range, step: 1).frame(width: 84)
            Text(label).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 24, alignment: .trailing)
        }
        .frame(height: 38)
    }

    private func styleBinding<Value>(_ keyPath: WritableKeyPath<AnnotationStyle, Value>) -> Binding<Value> {
        Binding(get: { model.style[keyPath: keyPath] }, set: { new in model.restyle { $0[keyPath: keyPath] = new } })
    }

    // MARK: Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { model.open(url: url) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { DispatchQueue.main.async { model.open(url: url) } }
        }
        return true
    }

    private func dragProvider() -> NSItemProvider {
        guard let url = model.dragFile(), let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        return provider
    }

    private func renderThumbnail() async {
        // Dragging a handle changes the marks many times a second; draw the small copy once things settle.
        try? await Task.sleep(nanoseconds: 220_000_000)
        guard !Task.isCancelled else { return }
        guard let doc = model.document else { thumbnail = nil; return }
        let scale = min(1, 520 / max(doc.size.width, doc.size.height, 1))
        let blurs = model.blurs
        let image = await Task.detached(priority: .utility) {
            AnnotateRenderer.render(image: doc.image, annotations: doc.annotations, blurs: blurs, scale: scale, opaque: true)
        }.value
        guard !Task.isCancelled else { return }
        thumbnail = image
    }

    // MARK: Keys

    /// Tool keys, ⌘Z, ⌘V and the rest work whenever this tool is on screen and nothing is being typed.
    private func installKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, !(window is NSPanel), window.attachedSheet == nil, !(window.firstResponder is NSText) else { return event }
            let used = MainActor.assumeIsolated { AnnotateScreenshotModel.shared.handle(event) }
            return used ? nil : event
        }
    }

    private func removeKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// A small toolbar button that lights up under the pointer.
private struct IconButton: View {
    let symbol: String
    let help: String
    var selected = false
    var enabled = true
    var bordered = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: bordered ? nil : 32, height: bordered ? 28 : 30)
                .frame(maxWidth: bordered ? .infinity : nil)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var background: Color {
        if selected { return Theme.accent }
        if bordered { return hovering ? Theme.tint.opacity(0.14) : Theme.inset }
        return hovering ? Theme.tint.opacity(0.10) : .clear
    }
}
