import SwiftUI

struct ResizeImagesView: View {
    @State private var model = ResizeImagesModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.hasItems { workspace } else {
                DropZone(title: "Drop Images Here", hint: "Drop files or a whole folder to process them in one go.", symbol: "doc.badge.arrow.up",
                         allowsFolders: true, button: "Choose Files...") { model.add($0) }
            }
            options.frame(width: 240)
        }
    }

    // MARK: Preview and queue

    private var workspace: some View {
        VStack(spacing: 10) {
            if let item = model.selected {
                ResizeCanvas(original: item.size, output: model.outputSize(for: item.size), image: model.previewImage,
                             isEnabled: !model.isRunning) { handle, w, h in model.drag(handle, width: w, height: h) }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
            }
            if model.items.count > 1 || model.items.contains(where: { $0.status != .waiting }) {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.items) { row($0) }
                    }
                }
                .frame(maxHeight: 150)
            } else if let item = model.selected {
                row(item)
            }
            HStack {
                Button("Add Images…") { chooseMore() }.disabled(model.isRunning)
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

    private func row(_ item: ResizeImagesModel.Item) -> some View {
        let selected = item.id == model.selectedID
        return HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting:
                    Text(plan(item)).font(.caption).foregroundStyle(.secondary)
                case .resizing:
                    ProgressView().controlSize(.small).scaleEffect(0.8, anchor: .leading)
                case .done(let r):
                    result(r)
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
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent, lineWidth: selected ? 1.5 : 0))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { if !selected { model.select(item.id) } }
    }

    /// "JPEG · 4032 × 3024 → 1920 × 1440"
    private func plan(_ item: ResizeImagesModel.Item) -> String {
        let to = model.outputSize(for: item.size)
        let size = "\(item.size.width) × \(item.size.height)"
        guard to != item.size else { return "\(item.kind) · \(size) · stays as it is" }
        return "\(item.kind) · \(size) → \(to.width) × \(to.height)"
    }

    @ViewBuilder private func result(_ r: ImageResizeResult) -> some View {
        switch r.outcome {
        case .resized:
            Label("\(r.from.width) × \(r.from.height) → \(r.to.width) × \(r.to.height) · \(MediaFormat.bytes(r.sourceBytes)) → \(MediaFormat.bytes(r.bytes))",
                  systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .unchanged:
            Label("\(r.from.width) × \(r.from.height) · already this size, copy saved", systemImage: "equal.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
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
                Picker("", selection: $model.settings.mode) {
                    ForEach(ResizeMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).padding(.vertical, 8)
                modeRows
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            Text(note).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    @ViewBuilder private var modeRows: some View {
        switch model.settings.mode {
        case .percentage:
            Divider()
            row("Scale") { PixelField(value: $model.settings.percent, range: ImageResizeSettings.percentRange, unit: "%") }
        case .longestSide:
            Divider()
            row("Longest side") { PixelField(value: $model.settings.longestSide, range: 1...ImageResizeSettings.maxPixels, unit: "px") }
            Divider()
            row("Enlarge smaller images") { Toggle("", isOn: $model.settings.enlarge).labelsHidden().toggleStyle(.switch) }
        case .size:
            Divider()
            row("Width") {
                PixelField(value: Binding(get: { model.settings.width }, set: { model.setWidth($0) }), range: 1...ImageResizeSettings.maxPixels, unit: "px")
            }
            Divider()
            row("Height") {
                PixelField(value: Binding(get: { model.settings.height }, set: { model.setHeight($0) }), range: 1...ImageResizeSettings.maxPixels, unit: "px")
            }
            Divider()
            row("Keep proportions") {
                Toggle("", isOn: Binding(get: { model.settings.keepProportions }, set: { model.setKeepProportions($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            Divider()
            row("Enlarge smaller images") { Toggle("", isOn: $model.settings.enlarge).labelsHidden().toggleStyle(.switch) }
        }
    }

    private var note: String {
        let s = model.settings
        switch s.mode {
        case .percentage:
            return "Every image is scaled to this share of its own size. Drag the handles on the preview to set it by eye."
        case .longestSide:
            return "The longer side of each image is set to this size. The other side follows its proportions."
        case .size:
            return s.keepProportions
                ? "Each image is scaled to fit inside this width and height, keeping its proportions."
                : "Every image is stretched to exactly this width and height."
        }
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
                    Button("Resize") { model.resize() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPending)
                }
            }
        }
    }
}

/// A number you can type or step, with its unit after it ("1920 px").
private struct PixelField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 48)
            Text(unit).font(.caption).foregroundStyle(.secondary)
            Stepper("", value: $value, in: range).labelsHidden()
        }
    }
}
