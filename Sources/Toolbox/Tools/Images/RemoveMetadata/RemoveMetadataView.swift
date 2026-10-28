import SwiftUI

struct RemoveMetadataView: View {
    @State private var model = RemoveMetadataModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { queue } else {
                DropZone(title: "Drop Photos Here", hint: "Drop files or a whole folder to process them in one go.", symbol: "doc.badge.arrow.up",
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
                Button("Add Photos…") { chooseMore() }.disabled(model.isRunning)
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

    private func row(_ item: RemoveMetadataModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting:
                    Text("\(item.kind) · \(MediaFormat.bytes(item.bytes)) · \(found(item.found))").font(.caption).foregroundStyle(.secondary)
                case .working:
                    ProgressView().controlSize(.small).scaleEffect(0.8, anchor: .leading)
                case .done(let r):
                    if r.removed.isEmpty {
                        Label("Nothing to remove · clean copy saved", systemImage: "equal.circle.fill").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Removed \(list(r.removed))", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    }
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

    /// "Location, camera, dates" or "No metadata found".
    private func found(_ kinds: Set<MetadataKind>) -> String { kinds.isEmpty ? "No metadata found" : list(kinds) }

    private func list(_ kinds: Set<MetadataKind>) -> String {
        kinds.sorted().enumerated().map { $0.offset == 0 ? $0.element.rawValue : $0.element.rawValue.lowercased() }.joined(separator: ", ")
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
            HStack {
                Text("Keep orientation").font(.callout).fixedSize()
                Spacer(minLength: 4)
                Toggle("", isOn: $model.settings.keepOrientation).labelsHidden().toggleStyle(.switch)
            }
            .padding(.horizontal, 10).frame(height: 38)
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
        var text = "Removes GPS location, camera details, dates and other EXIF, IPTC and XMP data."
        text += model.settings.keepOrientation
            ? " Only the rotation tag stays, so photos still open the right way up."
            : " Sideways photos are turned upright in the picture itself, so they look the same."
        return text
    }

    @ViewBuilder private var footer: some View {
        if model.isRunning {
            HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancel() } }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if model.doneCount > 0 && !model.hasPending {
                    Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                    Text("\(model.cleanedCount) of \(model.doneCount) photo\(model.doneCount == 1 ? "" : "s") had details removed. Originals are untouched.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.hasPending, !model.pendingKinds.isEmpty {
                    Text("Found: \(list(model.pendingKinds))").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Remove Metadata") { model.removeMetadata() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPending)
                }
            }
        }
    }
}
