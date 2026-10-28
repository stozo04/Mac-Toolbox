import SwiftUI

struct BlurFacesView: View {
    @State private var model = BlurFacesModel.shared
    @State private var before: CGImage?
    @State private var after: CGImage?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { queue } else {
                DropZone(title: "Drop Photos Here",
                         hint: "Faces are found and hidden on this Mac. Each photo keeps its format and orientation.",
                         symbol: "person.crop.square", allowsFolders: true, button: "Choose Files...") { model.add($0) }
            }
            options.frame(width: 240)
        }
        .task(id: previewRequest) { await loadPreview() }
    }

    // MARK: Queue

    private var queue: some View {
        VStack(spacing: 10) {
            preview
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

    /// Before and after for the selected photo, at the current style and strength.
    private var preview: some View {
        HStack(spacing: 10) {
            previewPane("Before", before)
            previewPane("After", after)
        }
        .frame(height: 250)
    }

    private func previewPane(_ title: String, _ image: CGImage?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: BlurFacesModel.Item) -> some View {
        let selected = item.id == model.selectedID
        return HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
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
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = item.id }
    }

    @ViewBuilder private func status(_ item: BlurFacesModel.Item) -> some View {
        switch item.status {
        case .detecting:
            ProgressView("Finding faces…").font(.caption).controlSize(.small).scaleEffect(0.8, anchor: .leading)
        case .ready:
            Text(foundText(item.faces.count)).font(.caption).foregroundStyle(.secondary)
        case .blurring:
            ProgressView("Hiding faces…").font(.caption).controlSize(.small).scaleEffect(0.8, anchor: .leading)
        case .done(let r):
            Label(hiddenText(r.facesHidden), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private func foundText(_ count: Int) -> String {
        switch count {
        case 0: "No faces found"
        case 1: "1 face found"
        default: "\(count) faces found"
        }
    }

    private func hiddenText(_ count: Int) -> String {
        switch count {
        case 0: "No faces hidden · saved unchanged"
        case 1: "1 face hidden"
        default: "\(count) faces hidden"
        }
    }

    private func chooseMore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    // MARK: Preview

    /// What the preview shows. Changing any part of it reloads the preview.
    private struct PreviewRequest: Equatable {
        let url: URL
        let settings: FaceBlurSettings
        let boxes: [CGRect]
    }

    private var previewRequest: PreviewRequest? {
        guard let item = model.selected else { return nil }
        switch item.status {
        case .ready, .blurring, .done: break
        case .detecting, .failed: return nil
        }
        return PreviewRequest(url: item.url, settings: model.settings, boxes: item.includedBoxes)
    }

    private func loadPreview() async {
        guard let request = previewRequest else {
            before = nil
            after = nil
            return
        }
        let pair = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
            guard let photo = ImageConverter.thumbnail(of: request.url, maxSize: 1000) else { return (nil, nil) }
            return (photo, FaceBlur.render(photo, faces: request.boxes, settings: request.settings))
        }.value
        guard !Task.isCancelled else { return }
        (before, after) = pair
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options").font(.headline)
            Text("Applies to every photo in this batch.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Style").font(.callout)
                    Picker("", selection: $model.settings.style) {
                        ForEach(FaceBlurStyle.allCases) { Text($0.label).tag($0) }
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
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            facesList
            Text("Each face is covered with a little extra margin. Photos without faces are saved unchanged.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private var strengthBinding: Binding<Double> {
        Binding(get: { Double(model.settings.strength) }, set: { model.settings.strength = Int($0) })
    }

    /// Each face found in the selected photo, with a switch to leave it visible.
    @ViewBuilder private var facesList: some View {
        if let item = model.selected, !item.faces.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Faces in this photo").font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.faces.enumerated()), id: \.element.id) { index, face in
                            Toggle("Face \(index + 1)", isOn: Binding(
                                get: { face.isIncluded },
                                set: { _ in model.toggle(face.id, in: item.id) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.callout)
                        }
                    }
                }
                .frame(maxHeight: 130)
                .disabled(model.isRunning)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if model.isRunning {
            HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancel() } }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if model.doneCount > 0 && !model.hasPending {
                    Label("\(model.hiddenCount) of \(model.doneCount) photos had faces hidden. Saved to Downloads.",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                HStack {
                    Spacer()
                    Button("Blur Faces") { model.blur() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPending || model.isDetecting)
                }
            }
        }
    }
}
