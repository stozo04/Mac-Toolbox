import SwiftUI

struct ResizeVideoView: View {
    @State private var model = ResizeVideoModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { queue } else {
                DropZone(title: "Drop Videos Here", hint: "Drop videos or a whole folder to resize them in one go.", symbol: "film",
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

    private func row(_ item: ResizeVideoModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .converting(let p): ProgressView(value: p)
                case .done(_, let bytes):
                    Label(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .failed(let message): Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if case .done(let url, _) = item.status {
                RevealButton { model.reveal(url) }
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
                row("Size") {
                    Picker("", selection: $model.preset) {
                        ForEach(SizePreset.all) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }
                Divider()
                row("Width") { numberField($model.width) }
                row("Height") { numberField($model.height) }
                Button { model.swapSize() } label: { Label("Swap Width and Height", systemImage: "arrow.left.arrow.right") }
                    .controlSize(.small).padding(.bottom, 10)
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text(model.isValidSize ? "Odd sizes are rounded down to the nearest even number, as video encoders require."
                 : "Width and height must be between 2 and 16384.")
                .font(.caption2).foregroundStyle(model.isValidSize ? Color.secondary : Color.red)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Keep aspect ratio").font(.callout)
                    Spacer()
                    Toggle("", isOn: $model.keepAspect).labelsHidden().toggleStyle(.switch)
                }
                if model.keepAspect {
                    Text("Fit").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $model.fit) {
                        ForEach(ResizeFit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }
            }
            .padding(10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text(model.keepAspect ? model.fit.explanation : "The video is stretched to the exact size, so the picture can look squashed.")
                .font(.caption2).foregroundStyle(.secondary)

            row("Format") {
                Picker("", selection: $model.codec) {
                    ForEach(ResizeCodec.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize()
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)

            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack { Text(title).font(.callout).fixedSize(); Spacer(minLength: 4); control() }.frame(height: 38)
    }

    private func numberField(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number.grouping(.never))
            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced)).frame(width: 80)
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
                    Button("Resize") { model.resize() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPending || !model.isValidSize)
                }
            }
        }
    }
}
