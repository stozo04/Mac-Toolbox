import SwiftUI

struct ExtractAudioView: View {
    @State private var model = ExtractAudioModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { queue } else {
                DropZone(title: "Drop Videos Here", hint: "Drop files or a whole folder to process them in one go.",
                         symbol: "arrow.down.doc", allowsFolders: true, button: "Choose Files...") { model.add($0) }
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
                if !model.results.isEmpty && !model.isRunning {
                    Button("Show in Finder") { model.revealFolder() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground(corner: 24)
        .fileDrop { model.add($0) }
    }

    private func row(_ item: ExtractAudioModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .extracting(let p): ProgressView(value: p)
                case .done(let r): doneLabel(r)
                case .noSoundtrack: Text("This video has no sound. Nothing was saved.").font(.caption).foregroundStyle(.secondary)
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

    private func doneLabel(_ r: ExtractAudioResult) -> some View {
        var parts = [r.url.pathExtension.uppercased(), MediaFormat.duration(r.duration), MediaFormat.bytes(r.bytes)]
        if r.copiedAsIs { parts.append("copied as is") }
        return Label(parts.joined(separator: " · "), systemImage: "checkmark.circle.fill")
            .font(.caption).foregroundStyle(.green)
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Options").font(.headline)
                Text("Applies to every file in this batch.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                optionRow("Format") {
                    Picker("", selection: $model.settings.format) {
                        ForEach(ExtractAudioFormat.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                Divider()
                optionRow("Bitrate") {
                    if model.settings.format.hasBitrate {
                        Picker("", selection: $model.settings.bitrate) {
                            ForEach(ExtractAudioBitrate.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden().fixedSize()
                    } else {
                        Text("Uncompressed").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text(formatNote).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private var formatNote: String {
        switch model.settings.format {
        case .m4a: "If the video already has AAC audio, it's copied as is, with no loss in quality."
        case .mp3: "MP3 plays everywhere. The sound is re-encoded at the bitrate you pick."
        case .wav, .aiff: "Uncompressed 16-bit audio at the video's own sample rate. Large files, no further loss."
        }
    }

    private func optionRow(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack { Text(title).font(.callout); Spacer(); control() }.frame(height: 38)
    }

    @ViewBuilder private var footer: some View {
        if model.isRunning {
            HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancel() } }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !model.results.isEmpty && !model.hasPending {
                    Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                }
                HStack {
                    Spacer()
                    Button("Extract Audio") { model.extract() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPending)
                }
            }
        }
    }
}
