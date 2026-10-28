import SwiftUI

struct MuteVideoView: View {
    @State private var model = MuteVideoModel.shared

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
                if !model.results.isEmpty && !model.isRunning {
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

    private func row(_ item: MuteVideoModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .muting(let p): ProgressView(value: p)
                case .done(let r): doneLabel(r)
                case .silent: Text("Already silent. Nothing was saved.").font(.caption).foregroundStyle(.secondary)
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

    private func doneLabel(_ r: MuteResult) -> some View {
        var parts = [MediaFormat.duration(r.duration), MediaFormat.bytes(r.newBytes)]
        if r.savedBytes > 0 { parts.append("\(MediaFormat.bytes(r.savedBytes)) smaller") }
        if r.reencoded { parts.append("re-encoded") }
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
            Text("Options").font(.headline)
            Text("Applies to every file in this batch.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                info("Video quality", "Unchanged")
                Divider()
                info("Format", "Same as original")
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("All audio tracks are removed. The picture is copied as is, so muting is fast and lossless.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack { Text(title).font(.callout); Spacer(); Text(value).font(.callout).foregroundStyle(.secondary) }.frame(height: 38)
    }

    @ViewBuilder private var footer: some View {
        if model.isRunning {
            HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancel() } }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !model.results.isEmpty && !model.hasPending {
                    Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                    if model.savedBytes > 0 {
                        Text("\(MediaFormat.bytes(model.savedBytes)) saved in total.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Mute") { model.mute() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPending)
                }
            }
        }
    }
}
