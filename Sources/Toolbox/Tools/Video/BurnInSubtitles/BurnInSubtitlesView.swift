import SwiftUI

struct BurnInSubtitlesView: View {
    @State private var model = BurnInSubtitlesModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { queue } else {
                DropZone(title: "Drop a Video Here", hint: "Drop a video, then choose its subtitles or let Toolbox transcribe it.",
                         symbol: "film", allowsFolders: true) { model.add($0) }
            }
            options.frame(width: 240)
        }
        .onChange(of: model.source, initial: true) { _, source in if source == .transcribe { model.loadLanguages() } }
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

    private func row(_ item: BurnInSubtitlesModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                status(item)
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

    @ViewBuilder private func status(_ item: BurnInSubtitlesModel.Item) -> some View {
        switch item.status {
        case .waiting:
            if model.source == .file, let file = model.subtitleFile(for: item) {
                Label(file.lastPathComponent, systemImage: "captions.bubble").font(.caption).foregroundStyle(.secondary)
            } else if model.source == .file {
                Text("Choose a subtitle file, or add one named like the video.").font(.caption).foregroundStyle(.orange)
            } else {
                Text("Waiting").font(.caption).foregroundStyle(.secondary)
            }
        case .transcribing(let p):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: p)
                Text("Transcribing speech…").font(.caption2).foregroundStyle(.secondary)
            }
        case .burning(let p):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: p)
                Text("Adding captions…").font(.caption2).foregroundStyle(.secondary)
            }
        case .done(let r):
            Label("\(r.cueCount) captions · \(MediaFormat.bytes(r.bytes))", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
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
                row("Subtitles") {
                    Picker("", selection: $model.source) {
                        ForEach(BurnInSubtitlesModel.Source.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(maxWidth: 135)
                }
                Divider()
                if model.source == .file {
                    row("File") {
                        Button(model.chosenFile?.lastPathComponent ?? "Choose…") { model.chooseSubtitleFile() }
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 120)
                    }
                } else {
                    row("Language") {
                        Picker("", selection: $model.languageID) {
                            ForEach(model.locales, id: \.identifier) { Text(SpeechTranscriber.name(of: $0)).tag($0.identifier) }
                        }.labelsHidden().frame(maxWidth: 120)
                    }
                    Divider()
                    row("Also save SRT") { Toggle("", isOn: $model.alsoSaveSubtitles).labelsHidden().toggleStyle(.switch) }
                }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text(model.source == .file
                 ? "Choose an SRT or WebVTT file. A subtitle file with the same name as the video is picked up automatically."
                 : "Speech is transcribed on this Mac. Nothing is uploaded.")
                .font(.caption2).foregroundStyle(.secondary)

            Text("Style").font(.headline).padding(.top, 4)
            VStack(spacing: 0) {
                row("Size") {
                    Picker("", selection: $model.style.size) {
                        ForEach(CaptionStyle.Size.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                Divider()
                row("Position") {
                    Picker("", selection: $model.style.position) {
                        ForEach(CaptionStyle.Position.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                Divider()
                row("Look") {
                    Picker("", selection: $model.style.look) {
                        ForEach(CaptionStyle.Look.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            CaptionPreview(style: model.style)

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
                if model.doneCount > 0 && !model.hasPending {
                    Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                }
                HStack {
                    Spacer()
                    Button("Burn In") { model.burn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasRunnable)
                }
            }
        }
    }
}

/// A sample caption drawn by the same code that draws the real ones.
private struct CaptionPreview: View {
    let style: CaptionStyle
    private static let video = CGSize(width: 1280, height: 720)

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / Self.video.width
            ZStack {
                LinearGradient(colors: [Color.gray.opacity(0.55), Color.gray.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                if let caption = CaptionRenderer.render("The quick brown fox jumps", style: style, videoSize: Self.video) {
                    Image(decorative: caption.image, scale: 1)
                        .resizable()
                        .frame(width: caption.frame.width * scale, height: caption.frame.height * scale)
                        .position(x: caption.frame.midX * scale, y: (Self.video.height - caption.frame.midY) * scale)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
