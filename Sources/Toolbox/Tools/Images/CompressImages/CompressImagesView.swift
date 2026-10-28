import SwiftUI

struct CompressImagesView: View {
    @State private var model = CompressImagesModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { queue } else {
                DropZone(title: "Drop Images Here", hint: "Drop files or a whole folder to process them in one go.", symbol: "doc.badge.arrow.up",
                         allowsFolders: true, button: "Choose Files...") { model.add($0) }
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

    private func row(_ item: CompressImagesModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting:
                    Text("\(item.kind) · \(MediaFormat.bytes(item.bytes))").font(.caption).foregroundStyle(.secondary)
                case .compressing:
                    ProgressView().controlSize(.small).scaleEffect(0.8, anchor: .leading)
                case .done(let r):
                    result(item, r)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if case .done(let r) = item.status {
                RevealButton { model.reveal(r.url) }
            } else if !model.isRunning {
                Button { model.remove(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove")
            }
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func result(_ item: CompressImagesModel.Item, _ r: CompressResult) -> some View {
        switch r.outcome {
        case .compressed:
            Label(summary(item, r), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .alreadySmall:
            Label("\(MediaFormat.bytes(r.sourceBytes)) · already as small as it gets, original kept", systemImage: "equal.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .unsupported:
            Label("\(item.kind) can't be compressed here, original kept. Choose JPEG or HEIC to shrink it.", systemImage: "equal.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "JPEG → JPEG · 4.8 MB → 640 KB · −87%"
    private func summary(_ item: CompressImagesModel.Item, _ r: CompressResult) -> String {
        let after = ImageFormat.name(forExtension: r.url.pathExtension)
        let what = after == item.kind ? item.kind : "\(item.kind) → \(after)"
        var text = "\(what) · \(MediaFormat.bytes(r.sourceBytes)) → \(MediaFormat.bytes(r.bytes))"
        if r.sourceBytes > 0 { text += " · −\(Int((Double(r.savedBytes) / Double(r.sourceBytes) * 100).rounded()))%" }
        return text
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Quality").font(.callout)
                Picker("", selection: $model.settings.level) {
                    ForEach(CompressLevel.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            .padding(10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text(model.settings.level.blurb).font(.caption2).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                row("Format") {
                    Picker("", selection: $model.settings.format) {
                        ForEach(CompressFormat.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().fixedSize()
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

    private var note: String {
        var text = "JPEG and HEIC photos are re-encoded. PNG and other lossless images are re-saved without extra data. If a file can't be made smaller, the original is kept."
        if model.settings.format == .jpeg { text += " JPEG can't be see-through, so transparent areas turn white." }
        return text
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
                    if model.savedBytes > 0 {
                        Text("\(MediaFormat.bytes(model.savedBytes)) smaller (\(Int((Double(model.savedBytes) / Double(max(model.originalBytes, 1)) * 100).rounded()))%)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Compress") { model.compress() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPending)
                }
            }
        }
    }
}
