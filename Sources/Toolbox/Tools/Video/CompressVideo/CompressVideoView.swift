import SwiftUI

struct CompressVideoView: View {
    @State private var model = CompressVideoModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { queue } else {
                DropZone(title: "Drop Videos Here", hint: "Drop videos or a whole folder to compress them in one go.", symbol: "arrow.down.doc",
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
                Button("Add Videos…") { chooseMore() }.disabled(model.isRunning)
                Button("Clear") { model.clear() }
                Spacer()
                if model.results.count > 0 && !model.isRunning {
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

    private func row(_ item: CompressVideoModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .compressing(let p): ProgressView(value: p)
                case .done(let r):
                    Label(summary(r), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case .notSmaller(let bytes):
                    Label("Already well compressed (\(MediaFormat.bytes(bytes))). A new copy would not be smaller, so none was made.",
                          systemImage: "info.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                case .failed(let message): Text(message).font(.caption).foregroundStyle(.red)
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

    /// "12.4 MB → 3.1 MB · −75%"
    private func summary(_ r: VideoCompressResult) -> String {
        "\(MediaFormat.bytes(r.originalBytes)) → \(MediaFormat.bytes(r.newBytes)) · −\(percent(r.savedFraction))%"
    }

    private func percent(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }

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
                Picker("", selection: $model.settings.quality) {
                    ForEach(VideoCompressQuality.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            .padding(10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text(model.settings.quality.blurb).font(.caption2).foregroundStyle(.secondary)

            VStack(spacing: 0) {
                row("Format") {
                    Picker("", selection: $model.settings.codec) {
                        ForEach(VideoCompressCodec.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                Divider()
                row("Maximum size") {
                    Picker("", selection: $model.settings.maxSize) {
                        ForEach(VideoCompressMaxSize.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text(model.settings.codec.note + " Videos are never enlarged.").font(.caption2).foregroundStyle(.secondary)

            VStack(spacing: 0) {
                row("Remove audio") { Toggle("", isOn: $model.settings.removeAudio).labelsHidden().toggleStyle(.switch) }
                Divider()
                row("Use hardware encoder") { Toggle("", isOn: $model.settings.hardwareEncoder).labelsHidden().toggleStyle(.switch) }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text("The hardware encoder is much faster but produces slightly larger files.").font(.caption2).foregroundStyle(.secondary)

            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack { Text(title).font(.callout).fixedSize(); Spacer(minLength: 4); control() }.frame(height: 38)
    }

    @ViewBuilder private var footer: some View {
        if model.isRunning {
            HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancel() } }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !model.results.isEmpty && !model.hasPending {
                    Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                    Text("\(MediaFormat.bytes(model.savedBytes)) smaller (\(percent(Double(model.savedBytes) / Double(max(model.originalBytes, 1))))% less)")
                        .font(.caption).foregroundStyle(.secondary)
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
