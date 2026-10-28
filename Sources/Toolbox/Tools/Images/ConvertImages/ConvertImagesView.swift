import SwiftUI

struct ConvertImagesView: View {
    @State private var model = ConvertImagesModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { queue } else {
                DropZone(title: "Drop Images Here", hint: "Drop photos or a whole folder to convert them in one go.", symbol: "photo",
                         allowsFolders: true) { model.add($0) }
            }
            options.frame(width: 240)
        }
    }

    // MARK: Queue

    private var queue: some View {
        VStack(spacing: 10) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.items) { row($0) }
                }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
            }
            HStack {
                Button("Add Images…") { chooseMore() }.disabled(model.isRunning)
                Button("Clear") { model.clear() }
                Spacer()
                if model.doneCount > 0 && !model.isRunning {
                    Button("Show in Finder") { model.revealFolder() }
                }
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

    private func row(_ item: ConvertImagesModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting:
                    Text("\(item.kind) · \(MediaFormat.bytes(item.bytes))").font(.caption).foregroundStyle(.secondary)
                case .converting:
                    ProgressView().controlSize(.small).scaleEffect(0.8, anchor: .leading)
                case .done(let r):
                    Label(summary(item, r), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if case .done(let r) = item.status {
                Button { model.reveal(r.url) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
            } else if !model.isRunning {
                Button { model.remove(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove")
            }
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "HEIC → WebP · 2.1 MB → 640 KB"
    private func summary(_ item: ConvertImagesModel.Item, _ r: ConvertResult) -> String {
        "\(item.kind) → \(ImageFormat.name(forExtension: r.url.pathExtension)) · \(MediaFormat.bytes(r.sourceBytes)) → \(MediaFormat.bytes(r.bytes))"
    }

    private func chooseMore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options").font(.headline)
            Text("Applies to every file in this batch.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                row("Format") {
                    Picker("", selection: $model.settings.format) {
                        ForEach(ImageFormat.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                if model.settings.format.isLossy && !lossless {
                    Divider()
                    VStack(spacing: 2) {
                        HStack {
                            Text("Quality").font(.callout)
                            Spacer()
                            Text("\(model.settings.quality)%").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: qualityBinding, in: 1...100, step: 1)
                    }.padding(.vertical, 8)
                }
                if model.settings.format == .webp {
                    Divider()
                    row("Lossless") { Toggle("", isOn: $model.settings.losslessWebP).labelsHidden().toggleStyle(.switch) }
                }
                Divider()
                row("Keep metadata") { Toggle("", isOn: $model.settings.keepMetadata).labelsHidden().toggleStyle(.switch) }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text(note).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private var lossless: Bool { model.settings.format == .webp && model.settings.losslessWebP }

    private var qualityBinding: Binding<Double> {
        Binding(get: { Double(model.settings.quality) }, set: { model.settings.quality = Int($0) })
    }

    private var note: String {
        var parts = ["Photos are turned upright and saved as new files. Originals stay untouched."]
        if !model.settings.format.supportsAlpha { parts.append("\(model.settings.format.label) can't be see-through, so transparent areas turn white.") }
        if model.settings.keepMetadata { parts.append("Camera, date and location details are kept. Turn this off to remove them.") }
        return parts.joined(separator: " ")
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack { Text(title).font(.callout).fixedSize(); Spacer(minLength: 4); control() }.frame(height: 38)
    }

    @ViewBuilder private var footer: some View {
        if model.isRunning {
            HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancel() } }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if model.doneCount > 0 && !model.hasPending {
                    Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                }
                HStack {
                    Spacer()
                    Button("Convert") { model.convert() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPending)
                }
            }
        }
    }
}
