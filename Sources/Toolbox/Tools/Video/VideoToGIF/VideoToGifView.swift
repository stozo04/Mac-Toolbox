import SwiftUI

struct VideoToGifView: View {
    @State private var model = VideoToGifModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { queue } else {
                DropZone(title: "Drop Videos Here", hint: "Drop files or a whole folder to process them in one go.", symbol: "film",
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

    private func row(_ item: VideoToGifModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .converting(let p): ProgressView(value: p)
                case .done(_, let bytes):
                    Label("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .failed(let message): Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if case .done(let url, _) = item.status {
                Button { model.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
            } else if !model.isRunning {
                Button { model.remove(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove")
            }
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                row("Frame rate") {
                    Picker("", selection: $model.fps) {
                        ForEach(GifSettings.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }.labelsHidden().fixedSize()
                }
                Divider()
                row("Width") {
                    Picker("", selection: $model.maxWidth) {
                        ForEach(GifSettings.widths, id: \.self) { Text($0.map { "\($0) px" } ?? "Original").tag($0) }
                    }.labelsHidden().fixedSize()
                }
                Divider()
                row("Loop forever") { Toggle("", isOn: $model.loopForever).labelsHidden().toggleStyle(.switch) }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text("Smaller sizes and lower frame rates make lighter GIFs. Videos are never enlarged.")
                .font(.caption2).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Convert only part of each video").font(.callout)
                    Spacer()
                    Toggle("", isOn: $model.partOnly).labelsHidden().toggleStyle(.switch)
                }
                if model.partOnly {
                    field("Start", text: $model.startText)
                    field("Duration", text: $model.lengthText)
                    if model.settings == nil {
                        Text("Enter times like 12.5 or 1:02.5.").font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            .padding(10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)

            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack { Text(title).font(.callout); Spacer(); control() }.frame(height: 38)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("0:00.00", text: text).textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing)
        }
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
                        .disabled(!model.hasPending || model.settings == nil)
                }
            }
        }
    }
}
