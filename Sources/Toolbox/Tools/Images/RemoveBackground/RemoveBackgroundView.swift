import SwiftUI

struct RemoveBackgroundView: View {
    @State private var model = RemoveBackgroundModel.shared
    @State private var before: CGImage?
    @State private var after: CGImage?
    @State private var afterError: String?

    var body: some View {
        if model.hasItems { workspace } else {
            HStack(alignment: .top, spacing: 14) {
                DropZone(title: "Drop Photos Here",
                         hint: "The subject is lifted out on this Mac. Each cutout is saved as a PNG so transparent areas are kept.",
                         symbol: "person.crop.rectangle", allowsFolders: true, button: "Choose Files...") { model.add($0) }
                options.frame(width: 240)
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                HStack(spacing: 14) {
                    pane("Before", detail: model.selected?.name, image: before)
                    pane("After", detail: model.settings.background.kind, image: after, error: afterError,
                         checkered: model.settings.background == .transparent)
                }
                options.frame(width: 240)
            }
            HStack(alignment: .top, spacing: 14) {
                files
                cutoutsCard.frame(width: 240)
            }
            .frame(height: 190)
        }
        .task(id: previewRequest) { await loadPreview() }
    }

    // MARK: Preview

    private func pane(_ title: String, detail: String?, image: CGImage?, error: String? = nil, checkered: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.inset)
                if checkered {
                    Checkerboard().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding(12)
                } else if let error {
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(16)
                } else if model.selected == nil {
                    Text("Choose a photo to preview it.").font(.callout).foregroundStyle(.secondary)
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

    private func row(_ item: RemoveBackgroundModel.Item) -> some View {
        let selected = item.id == model.selectedID
        return HStack(spacing: 10) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
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

    @ViewBuilder private func status(_ item: RemoveBackgroundModel.Item) -> some View {
        switch item.status {
        case .waiting:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .cutting:
            ProgressView().controlSize(.small)
        case .done:
            Label("Saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
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

    // MARK: Cutouts count

    private var cutoutsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cutouts").font(.headline)
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
                    Button("Remove Background") { model.removeBackgrounds() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPending)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(corner: 24)
    }

    private var footerText: String {
        if model.isRunning { return "Removing backgrounds…" }
        if model.doneCount > 0 && !model.hasPending { return "Saved to Downloads" }
        return "Ready when you are"
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options").font(.headline)
            Text("Applies to every photo in this batch.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                row("Background") {
                    Picker("", selection: $model.settings.background) {
                        ForEach(CutoutBackground.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
                if model.settings.background == .custom {
                    Divider()
                    row("Color") { ColorPicker("", selection: colorBinding).labelsHidden() }
                }
                Divider()
                row("Crop to subject") {
                    Toggle("", isOn: $model.settings.cropToSubject).labelsHidden().toggleStyle(.switch)
                }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text("Results are saved as PNG files so transparent areas are kept.")
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

    // MARK: Preview loading

    /// What the preview shows. Changing any part of it reloads the preview.
    private struct PreviewRequest: Equatable {
        let url: URL
        let settings: RemoveBackgroundSettings
    }

    private var previewRequest: PreviewRequest? {
        guard let item = model.selected else { return nil }
        return PreviewRequest(url: item.url, settings: model.settings)
    }

    private func loadPreview() async {
        guard let request = previewRequest else {
            before = nil
            after = nil
            afterError = nil
            return
        }
        let pair = await Task.detached(priority: .userInitiated) { () -> (CGImage?, Result<CGImage, Error>) in
            guard let photo = ImageConverter.thumbnail(of: request.url, maxSize: 1000) else {
                return (nil, .failure(RemoveBackgroundError.unreadable))
            }
            return (photo, Result { try RemoveBackground.cutout(photo, settings: request.settings) })
        }.value
        guard !Task.isCancelled else { return }
        before = pair.0
        switch pair.1 {
        case .success(let cutout):
            after = cutout
            afterError = nil
        case .failure(let error):
            after = nil
            afterError = error.localizedDescription
        }
    }
}
