import SwiftUI

struct RedactImageView: View {
    @State private var model = RedactImageModel.shared
    /// The selected image at preview size, and the same image with its regions covered.
    @State private var base: CGImage?
    @State private var baseURL: URL?
    @State private var shown: CGImage?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { workspace } else {
                DropZone(title: "Drop Images Here",
                         hint: "Drag over anything you want hidden. Each image keeps its format and full size.",
                         symbol: "eye.slash", allowsFolders: true, button: "Choose Files...") { model.add($0) }
            }
            options.frame(width: 240)
        }
        .task(id: previewRequest) { await refreshPreview() }
    }

    // MARK: Workspace

    private var workspace: some View {
        VStack(spacing: 10) {
            canvas
            if let item = model.selected { info(item) }
            if model.items.count > 1 { strip }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
            }
            HStack {
                Button("Add Images…") { chooseMore() }.disabled(model.isBusy)
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

    private var canvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.inset)
            if let item = model.selected {
                RedactCanvas(image: shown, pixelSize: item.size, regions: item.regions, selectedID: model.selectedRegionID,
                             isEnabled: !model.isBusy,
                             onSelect: { model.selectedRegionID = $0 },
                             onCreate: { model.addRegion($0) },
                             onChange: { model.setRect($1, of: $0) })
                    .padding(10)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .overlay(alignment: .topTrailing) {
            if let item = model.selected, !item.regions.isEmpty {
                Label("\(item.regions.count) hidden", systemImage: "eye.slash")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.orange, in: Capsule())
                    .padding(12)
            }
        }
        .overlay(alignment: .bottom) {
            if let item = model.selected, item.regions.isEmpty, !model.isBusy {
                Text("Drag over anything you want hidden")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// File name, size and what happened to it.
    private func info(_ item: RedactImageModel.Item) -> some View {
        HStack(spacing: 8) {
            Text(item.name).lineLimit(1).truncationMode(.middle).font(.callout)
            Text("\(item.size.width) × \(item.size.height) · \(MediaFormat.bytes(item.bytes))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            switch item.status {
            case .ready:
                EmptyView()
            case .working:
                ProgressView().controlSize(.small)
            case .done(let r):
                Label("Saved · \(MediaFormat.bytes(r.bytes))", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                RevealButton { model.reveal(r.url) }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if model.items.count > 1 {
                Button { model.remove(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove from the list").disabled(model.isBusy)
            }
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.items) { tile($0) }
            }
            .padding(2)
        }
        .frame(height: 64)
    }

    private func tile(_ item: RedactImageModel.Item) -> some View {
        let selected = item.id == model.selectedID
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.inset)
            if let thumb = item.thumbnail {
                Image(decorative: thumb, scale: 1).resizable().scaledToFill()
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) { badge(item).padding(3) }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { if !model.isBusy { model.select(item.id) } }
        .help(item.name)
    }

    @ViewBuilder private func badge(_ item: RedactImageModel.Item) -> some View {
        switch item.status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).font(.callout)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red).font(.callout)
        case .ready, .working:
            if !item.regions.isEmpty {
                Text("\(item.regions.count)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color.orange, in: Capsule())
            }
        }
    }

    private func chooseMore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    // MARK: Preview

    /// What the canvas shows. Changing any part of it redraws the picture.
    private struct PreviewRequest: Equatable {
        let url: URL
        let rects: [CGRect]
        let settings: RedactSettings
    }

    private var previewRequest: PreviewRequest? {
        guard let item = model.selected else { return nil }
        return PreviewRequest(url: item.url, rects: item.rects, settings: model.settings)
    }

    private func refreshPreview() async {
        guard let request = previewRequest else {
            base = nil; baseURL = nil; shown = nil
            return
        }
        if baseURL != request.url {
            base = nil; shown = nil
            let url = request.url
            let loaded = await Task.detached(priority: .userInitiated) { ImageConverter.thumbnail(of: url, maxSize: 1600) }.value
            guard !Task.isCancelled else { return }
            base = loaded
            baseURL = url
        }
        guard let photo = base else { return }
        let covered = await Task.detached(priority: .userInitiated) {
            RedactImage.render(photo, regions: request.rects, settings: request.settings)
        }.value
        guard !Task.isCancelled else { return }
        shown = covered
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    styleCard
                    findSection
                    regionsSection
                    Text("Blurred or pixelated text can sometimes be made out. Use Black Box for names, account numbers, addresses and license plates.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private var styleCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cover with").font(.callout)
                Picker("", selection: $model.settings.style) {
                    ForEach(RedactStyle.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            .padding(.vertical, 8)
            Divider()
            HStack {
                Text("Strength").font(.callout)
                Spacer(minLength: 4)
                Slider(value: strengthBinding, in: 1...100, step: 1)
                    .frame(width: 110)
                    .disabled(model.settings.style == .blackBox)
            }
            .frame(height: 38)
            Divider()
            HStack {
                Text("Remove metadata").font(.callout).fixedSize()
                Spacer(minLength: 4)
                Toggle("", isOn: $model.settings.removeMetadata).labelsHidden().toggleStyle(.switch)
            }
            .frame(height: 38)
            .help("Leaves location, camera and date details out of the copy")
        }
        .padding(.horizontal, 10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(model.isRunning)
    }

    private var strengthBinding: Binding<Double> {
        Binding(get: { Double(model.settings.strength) }, set: { model.settings.strength = Int($0) })
    }

    private var findSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Find & Cover").font(.callout)
            if model.items.count > 1 {
                Picker("", selection: $model.scope) {
                    ForEach(RedactImageModel.Scope.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            ForEach(RedactFind.allCases) { kind in
                Button { model.find(kind) } label: {
                    HStack(spacing: 6) {
                        if model.finding == kind { ProgressView().controlSize(.small) } else { Image(systemName: kind.symbol).frame(width: 16) }
                        Text(kind.label).lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.hasItems || model.isBusy)
            }
            if let message = model.findMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var regionsSection: some View {
        let count = model.selected?.regions.count ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(count == 0 ? "No regions on this image" : count == 1 ? "1 region on this image" : "\(count) regions on this image").font(.callout)
            HStack {
                Button("Remove Region") { model.deleteSelectedRegion() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selectedRegionID == nil || model.isBusy)
                Button("Clear All") { model.clearRegions() }
                    .disabled(count == 0 || model.isBusy)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var footer: some View {
        if model.isRunning {
            HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancel() } }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if model.doneCount > 0 && !model.hasExportable {
                    Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                    Text("\(model.doneCount) image\(model.doneCount == 1 ? "" : "s") exported. Originals are untouched.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.untouchedCount > 0, model.hasExportable {
                    Text("\(model.untouchedCount) image\(model.untouchedCount == 1 ? " has" : "s have") no regions and won't be exported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Export Redacted") { model.export() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasExportable || model.finding != nil)
                }
            }
        }
    }
}
