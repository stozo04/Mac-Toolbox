import AVKit
import ImageIO
import SwiftUI

struct ExtractFramesView: View {
    @State private var model = ExtractFramesModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { workspace } else {
                DropZone(title: "Drop Videos Here",
                         hint: "Save stills every few seconds, a set number of frames, or\none frame at a time you choose.",
                         symbol: "film", allowsFolders: true, button: "Choose Files...") { model.add($0) }
            }
            options.frame(width: 240)
        }
    }

    // MARK: Workspace

    private var workspace: some View {
        VStack(spacing: 10) {
            queue
            Divider()
            if model.mode == .manual, model.selected != nil { picker }
            frames
            Spacer(minLength: 0)
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Add Videos…") { chooseMore() }.disabled(model.isRunning)
                Button("Clear") { model.clear() }
                Spacer()
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

    private var queue: some View {
        ScrollView {
            LazyVStack(spacing: 6) { ForEach(model.items) { row($0) } }
        }
        .frame(maxHeight: model.items.count > 3 ? 170 : CGFloat(model.items.count) * 58)
    }

    private func row(_ item: ExtractFramesModel.Item) -> some View {
        let isSelected = item.id == model.selectedID
        return HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting:
                    Text(waitingText(item)).font(.caption).foregroundStyle(.secondary)
                case .working(let p): ProgressView(value: p)
                case .done:
                    Label(doneText(item), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case .failed(let message): Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if let zip = item.zip { RevealButton(help: "Show ZIP in Finder") { model.reveal(zip) } }
            else if let folder = item.folder { RevealButton { model.reveal(folder) } }
            if !model.isRunning {
                Button { model.remove(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove")
            }
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = item.id }
    }

    private func waitingText(_ item: ExtractFramesModel.Item) -> String {
        var parts = ["Waiting"]
        if let d = item.duration { parts.append(TrimTime.format(d)) }
        if item.savedCount > 0 { parts.append("\(item.savedCount) saved by hand") }
        return parts.joined(separator: " · ")
    }

    private func doneText(_ item: ExtractFramesModel.Item) -> String {
        let n = "\(item.savedCount) frame\(item.savedCount == 1 ? "" : "s")"
        if let zip = item.zip { return item.folder == nil ? "\(n) in \(zip.lastPathComponent)" : "\(n) saved, plus a ZIP" }
        return "\(n) saved in \(item.folder?.lastPathComponent ?? "")"
    }

    // MARK: Pick by hand

    private var picker: some View {
        VStack(spacing: 8) {
            PlayerSurface(player: model.player)
                .frame(minHeight: 220, maxHeight: 340)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 8) {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }.help("Previous frame")
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }.help("Next frame")
                Slider(value: Binding(get: { model.playhead }, set: { model.seek(to: $0) }),
                       in: scrubRange)
                Text(TrimTime.format(max(0, model.playhead - (model.selected?.videoStart ?? 0)))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    model.saveCurrentFrame()
                } label: { Label("Save Frame", systemImage: "camera") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSavingOne || model.settings == nil)
            }
        }
    }

    /// The picture's own span in the file; usually 0 to its length.
    private var scrubRange: ClosedRange<Double> {
        let start = model.selected?.videoStart ?? 0
        return start...(start + max(model.selected?.duration ?? 1, 0.01))
    }

    // MARK: Frames

    @ViewBuilder private var frames: some View {
        if let item = model.selected, !item.frames.isEmpty {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(item.frames, id: \.self) { FrameTile(url: $0, model: model) }
                }
            }
            .frame(maxHeight: .infinity)
        } else if let item = model.selected, item.status == .done, item.zip != nil {
            placeholder("archivebox", "Saved as \(item.zip!.lastPathComponent). The preview is skipped with ZIP only.")
        } else if model.mode != .manual {
            placeholder("photo.on.rectangle", model.selected?.status == .waiting
                        ? "Frames appear here as they are saved." : "Select a video to see its frames.")
        } else {
            placeholder("camera", "Frames you save appear here.").frame(maxHeight: 80)
        }
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseMore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsList.disabled(model.isRunning)
            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Options").font(.headline)
                Text("Applies to every file in this batch.").font(.caption).foregroundStyle(.secondary)
            }
            group {
                optionRow("Frames") {
                    Picker("", selection: $model.mode) {
                        ForEach(FrameMode.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                switch model.mode {
                case .everySeconds:
                    Divider()
                    optionRow("Every (seconds)") { number($model.interval, format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))) }
                case .perSecond:
                    Divider()
                    optionRow("Per second") {
                        Stepper("\(model.fps)", value: $model.fps, in: FrameSettings.fpsRange).fixedSize()
                    }
                case .total:
                    Divider()
                    optionRow("Frames per video") { number($model.total, format: IntegerFormatStyle<Int>.number) }
                case .manual: EmptyView()
                }
            }
            caption(FramePlan.summary(model.settings ?? FrameSettings(mode: model.mode, interval: model.interval,
                                                                       fps: model.fps, total: model.total)))

            if model.mode != .manual {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Only part of each video").font(.callout)
                        Spacer()
                        Toggle("", isOn: $model.partOnly).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    if model.partOnly {
                        field("Start", placeholder: "0:00.00", text: $model.startText)
                        field("End", placeholder: "end of video", text: $model.endText)
                        if model.settings == nil {
                            Text("Enter times like 12.5 or 1:02.5. End must be after Start.").font(.caption2).foregroundStyle(.red)
                        }
                    }
                }
                .padding(10)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            group {
                optionRow("Format") {
                    Picker("", selection: $model.format) {
                        ForEach(FrameFormat.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                if model.format.isLossy {
                    Divider()
                    optionRow("Quality") {
                        Slider(value: $model.quality, in: 0.3...1).frame(width: 90)
                        Text("\(Int((model.quality * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                    }
                }
                Divider()
                optionRow("Size") {
                    Picker("", selection: $model.maxSide) {
                        ForEach(FrameSettings.sizes, id: \.self) { Text($0.map { "\($0) px" } ?? "Original").tag($0) }
                    }.labelsHidden().fixedSize()
                }
                if model.mode != .manual {
                    Divider()
                    optionRow("Save as") {
                        Picker("", selection: $model.output) {
                            ForEach(FrameOutput.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
            }
            group {
                optionRow("Save to") {
                    Menu(model.customFolder?.lastPathComponent ?? "Next to video") {
                        Button("Next to Each Video") { model.customFolder = nil }
                        Button("Choose Folder…") { model.chooseFolder() }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            caption("Each video gets its own \"Frames\" folder" + (model.customFolder == nil ? " next to it." : " in \(model.customFolder!.lastPathComponent).")
                    + " Frames are never enlarged."
                    + (model.output == .zipOnly && model.mode != .manual ? " ZIP only skips the preview." : ""))
        }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func optionRow<Content: View>(_ title: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack { Text(title).font(.callout).lineLimit(1).fixedSize(); Spacer(); control() }.frame(height: 34)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func number<F: ParseableFormatStyle>(_ value: Binding<F.FormatInput>, format: F) -> some View where F.FormatOutput == String {
        TextField("", value: value, format: format)
            .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 60)
            .font(.callout.monospacedDigit())
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder private var footer: some View {
        if model.isRunning {
            HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancel() } }
        } else if model.mode != .manual {
            VStack(alignment: .leading, spacing: 6) {
                if let n = model.estimatedCount {
                    Text(model.exceedsLimit ? "Over \(FramePlan.maxFrames) frames for one video. Lower the rate or use part of it."
                         : "About \(n) frame\(n == 1 ? "" : "s") in all.")
                        .font(.caption).foregroundStyle(model.exceedsLimit ? .red : .secondary)
                }
                HStack {
                    Spacer()
                    Button(model.hasItems && !model.hasPending ? "Extract Again" : "Extract Frames") { model.extract() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasItems || model.settings == nil)
                }
            }
        }
    }
}

/// One saved frame: thumbnail, name, and the usual file actions. Drag it out to use it elsewhere.
private struct FrameTile: View {
    let url: URL
    let model: ExtractFramesModel
    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                    else { Color.clear.overlay(ProgressView().controlSize(.small)) }
                }
                .frame(maxWidth: .infinity).frame(height: 100)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if hovering { RevealButton { model.reveal(url) }.padding(4).background(.ultraThinMaterial, in: Circle()).padding(4) }
            }
            Text(url.lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { model.open(url) }
            Button("Show in Finder") { model.reveal(url) }
            Button("Copy") { model.copy(url) }
        }
        .task(id: url) { image = await Self.thumbnail(url) }
        .help(url.lastPathComponent)
    }

    private static func thumbnail(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 360,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        }.value
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
