import SwiftUI

struct MediaInfoView: View {
    @State private var model = MediaInfoModel.shared

    var body: some View {
        if model.hasItems {
            HStack(alignment: .top, spacing: 14) {
                list.frame(width: 240)
                detail
            }
        } else {
            DropZone(title: "Drop Videos or Audio Here",
                     hint: "See codecs, resolution, frame rate, bitrate and metadata. Nothing is changed.",
                     symbol: "info.circle", allowsFolders: true) { model.add($0) }
        }
    }

    // MARK: File list

    private var list: some View {
        VStack(spacing: 10) {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.items) { listRow($0) }
                }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
            }
            HStack {
                Button("Add Files…") { chooseMore() }
                Spacer()
                Button("Clear") { model.clear() }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity)
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

    private func listRow(_ item: MediaInfoModel.Item) -> some View {
        let selected = model.selection == item.id
        return Button { model.selection = item.id } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(item)).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    switch item.state {
                    case .reading: Text("Reading…").font(.caption).foregroundStyle(.secondary)
                    case .ready(let r): Text(MediaFormat.duration(r.duration)).font(.caption).foregroundStyle(.secondary)
                    case .failed: Text("Can't be read").font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 0)
                Button { model.remove(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.25) : Theme.inset,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(_ item: MediaInfoModel.Item) -> String {
        if case .ready(let r) = item.state { return r.hasVideo ? "film" : "waveform" }
        return "doc"
    }

    private func chooseMore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.selected?.state {
            case .ready(let report)?:
                ScrollView { report.sections(model: model) }
                actions
            case .failed(let message)?:
                Spacer()
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).frame(maxWidth: .infinity)
                Spacer()
            case .reading?:
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Spacer()
            case nil:
                Spacer()
                Text("Choose a file").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private var actions: some View {
        HStack {
            export("Copy as Text") { model.copyText(all: $0) }
            export("Export as JSON…") { model.exportJSON(all: $0) }
            if let flash = model.flash {
                Label(flash, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            }
            Spacer()
        }
    }

    /// A button for the selected file; a menu with "All files" as well when there are several.
    @ViewBuilder private func export(_ title: String, _ action: @escaping (Bool) -> Void) -> some View {
        if model.reports.count > 1 {
            Menu(title) {
                Button("This File") { action(false) }
                Button("All \(model.reports.count) Files") { action(true) }
            }.fixedSize()
        } else {
            Button(title) { action(false) }
        }
    }
}

// MARK: Report sections

private extension MediaReport {
    @ViewBuilder func sections(model: MediaInfoModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(fileName).font(.title3.weight(.semibold)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            card("Summary", [
                ("Size", MediaFormat.bytes(sizeBytes)),
                ("Format", container),
                ("Duration", MediaFormat.duration(duration)),
                ("Overall bitrate", overallBitrate.map(MediaFormat.bitrate)),
                ("Created", creationDate.map(MediaFormat.date)),
            ])
            ForEach(Array(videoTracks.enumerated()), id: \.offset) { i, v in
                card(videoTracks.count > 1 ? "Video track \(i + 1)" : "Video track", [
                    ("Codec", v.codec),
                    ("Resolution", MediaFormat.resolution(v.width, v.height)),
                    ("Rotation", v.rotation == 0 ? nil : "\(v.rotation)°"),
                    ("Frame rate", v.frameRate.map(MediaFormat.frameRate)),
                    ("Bitrate", v.bitrate.map(MediaFormat.bitrate)),
                    ("Color", v.dynamicRange),
                    ("Color primaries", v.colorPrimaries),
                    ("Bit depth", v.bitDepth.map { "\($0)-bit" }),
                    ("Language", v.language),
                ])
            }
            ForEach(Array(audioTracks.enumerated()), id: \.offset) { i, a in
                card(audioTracks.count > 1 ? "Audio track \(i + 1)" : "Audio track", [
                    ("Codec", a.codec),
                    ("Sample rate", a.sampleRate.map(MediaFormat.sampleRate)),
                    ("Channels", a.channels.map(MediaFormat.channels)),
                    ("Bit depth", a.bitDepth.map { "\($0)-bit" }),
                    ("Bitrate", a.bitrate.map(MediaFormat.bitrate)),
                    ("Language", a.language),
                ])
            }
            ForEach(Array(otherTracks.enumerated()), id: \.offset) { _, o in
                card("\(o.kind) track", [("Codec", o.codec), ("Language", o.language)])
            }
            metadataCard(model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ title: String, _ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.vertical, 8)
            ForEach(Array(rows.compactMap { r in r.1.map { (r.0, $0) } }.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider() }
                line(row.0, row.1)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metadataCard(_ model: MediaInfoModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Metadata").font(.headline).padding(.vertical, 8)
            if location == nil && metadata.isEmpty {
                Text("No metadata is stored in this file.").font(.callout).foregroundStyle(.secondary).padding(.bottom, 10)
            }
            if let location {
                HStack {
                    Text("Location").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(MediaFormat.coordinates(location)).font(.callout).textSelection(.enabled)
                    Button("Open in Maps") { model.openInMaps(location) }.controlSize(.small)
                }
                .frame(minHeight: 32)
                if !metadata.isEmpty { Divider() }
            }
            ForEach(Array(metadata.enumerated()), id: \.offset) { i, item in
                if i > 0 { Divider() }
                line(item.label, item.value)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).font(.callout).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .frame(minHeight: 32)
    }
}
