import SwiftUI
import UniformTypeIdentifiers

struct BeautifyScreenshotView: View {
    @State private var model = BeautifyScreenshotModel.shared
    @State private var framed: CGImage?

    var body: some View {
        if model.hasItems { workspace } else {
            HStack(alignment: .top, spacing: 14) {
                DropZone(title: "Drop Screenshots Here",
                         hint: "Each screenshot gets a background, padding and rounded corners, saved as a new PNG.",
                         symbol: "sparkles.rectangle.stack", allowsFolders: true, button: "Choose Files...") { model.add($0) }
                options.frame(width: 240)
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                preview
                options.frame(width: 240)
            }
            HStack(alignment: .top, spacing: 14) {
                files
                framedCard.frame(width: 240)
            }
            .frame(height: 190)
        }
        .task(id: previewRequest) { await loadPreview() }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview").font(.headline)
                    if let item = model.selected {
                        Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if let item = model.selected, item.pixelSize != .zero {
                    Text("\(Int(item.pixelSize.width)) × \(Int(item.pixelSize.height)) PNG")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.inset, in: Capsule())
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.inset)
                if model.settings.background == .transparent {
                    Checkerboard().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if let framed {
                    Image(decorative: framed, scale: 1).resizable().scaledToFit().padding(12)
                } else if model.selected == nil {
                    Text("Choose a screenshot to preview it.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground(corner: 24)
    }

    // MARK: Files

    private var files: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files").font(.headline)
                    Text("\(model.items.count) · \(MediaFormat.bytes(model.totalBytes))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { chooseMore() } label: { Label("Add Files…", systemImage: "plus") }
                    .disabled(model.isRunning)
                Button("Clear") { model.clear() }
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.items) { row($0) }
                }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground(corner: 24)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.add([url]) } }
                }
            }
            return true
        }
    }

    private func row(_ item: BeautifyScreenshotModel.Item) -> some View {
        let selected = item.id == model.selectedID
        return HStack(spacing: 10) {
            Group {
                if let thumb = item.thumbnail {
                    Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(MediaFormat.bytes(item.bytes)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            status(item)
            if case .done(let r) = item.status {
                RevealButton { model.reveal(r.url) }
            } else if !model.isRunning {
                Button { model.remove(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove")
            }
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = item.id }
    }

    @ViewBuilder private func status(_ item: BeautifyScreenshotModel.Item) -> some View {
        switch item.status {
        case .loading:
            Text("Reading…").font(.caption).foregroundStyle(.secondary)
        case .waiting:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .framing:
            ProgressView().controlSize(.small)
        case .done:
            Label("Framed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 160, alignment: .trailing)
        }
    }

    private func chooseMore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    // MARK: Framed count

    private var framedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Framed").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(model.doneCount)").font(.system(size: 40, weight: .bold)).monospacedDigit()
                Text("of \(model.items.count)").font(.title3).foregroundStyle(.secondary)
            }
            Text(footerText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                } else {
                    Button("Beautify") { model.beautify() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPending || model.isLoading)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(corner: 24)
    }

    private var footerText: String {
        if model.isRunning { return "Framing…" }
        if model.doneCount > 0 && !model.hasPending { return "Saved to Downloads" }
        if model.isLoading { return "Reading screenshots…" }
        return "Ready when you are"
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options").font(.headline)
            Text("Applies to every screenshot in this batch.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                row("Background") {
                    Picker("", selection: $model.settings.background) {
                        ForEach(BeautifyBackground.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
                if model.settings.background == .custom {
                    Divider()
                    row("Color") { ColorPicker("", selection: colorBinding).labelsHidden() }
                }
                if model.settings.background == .image {
                    Divider()
                    row("Image") {
                        Button(model.settings.imageURL?.lastPathComponent ?? "Choose…") { chooseBackground() }
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Divider()
                row("Aspect ratio") {
                    Picker("", selection: $model.settings.ratio) {
                        ForEach(BeautifyRatio.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("Padding").font(.callout).fixedSize()
                    Spacer(minLength: 4)
                    Text("S").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $model.settings.padding, in: 0...1).frame(width: 90)
                    Text("L").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(height: 38)
                Divider()
                HStack(spacing: 6) {
                    Text("Corner radius").font(.callout).fixedSize()
                    Spacer(minLength: 4)
                    Slider(value: $model.settings.cornerRadius, in: 0...40, step: 1).frame(width: 80)
                    Text("\(Int(model.settings.cornerRadius)) pt").font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .frame(height: 38)
                Divider()
                row("Shadow") {
                    Picker("", selection: $model.settings.shadow) {
                        ForEach(BeautifyShadow.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)

            Text("Saved as PNG at the screenshot's own resolution. Nothing is scaled up.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack { Text(title).font(.callout).fixedSize(); Spacer(minLength: 4); control() }.frame(height: 38)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { let c = model.settings.customColor; return Color(red: c.red, green: c.green, blue: c.blue) },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
                model.settings.customColor = RGBColor(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
            }
        )
    }

    private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { model.settings.imageURL = panel.url }
    }

    // MARK: Preview loading

    private struct PreviewRequest: Equatable {
        let url: URL
        let settings: BeautifySettings
    }

    private var previewRequest: PreviewRequest? {
        guard let item = model.selected, item.status != .loading, !isFailed(item) else { return nil }
        return PreviewRequest(url: item.url, settings: model.settings)
    }

    private func isFailed(_ item: BeautifyScreenshotModel.Item) -> Bool {
        if case .failed = item.status { return true }
        return false
    }

    private func loadPreview() async {
        guard let request = previewRequest else {
            framed = nil
            return
        }
        let image = await Task.detached(priority: .userInitiated) { BeautifyScreenshot.preview(of: request.url, settings: request.settings) }.value
        guard !Task.isCancelled else { return }
        framed = image
    }
}

/// The light and dark squares behind a transparent preview, so see-through areas read as transparent.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            for row in 0..<Int(size.height / cell) + 1 {
                for col in 0..<Int(size.width / cell) + 1 where (row + col) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.gray.opacity(0.25)))
                }
            }
        }
    }
}
