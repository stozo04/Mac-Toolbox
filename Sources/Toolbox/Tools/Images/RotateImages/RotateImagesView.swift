import SwiftUI

struct RotateImagesView: View {
    @State private var model = RotateImagesModel.shared

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
            preview
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

    /// The selected photo as it will be saved.
    private var preview: some View {
        ZStack {
            if let image = model.preview {
                Image(decorative: image, scale: 1)
                    .resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    .padding(24)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .top) {
            if let item = model.selected {
                Text(sizeText(item)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.top, 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func row(_ item: RotateImagesModel.Item) -> some View {
        let selected = item.id == model.selectedID
        return HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting:
                    Text("\(item.kind) · \(sizeText(item))").font(.caption).foregroundStyle(.secondary)
                case .rotating:
                    ProgressView().controlSize(.small).scaleEffect(0.8, anchor: .leading)
                case .done(let r):
                    Label("\(r.from.width) × \(r.from.height) → \(r.to.width) × \(r.to.height) · \(MediaFormat.bytes(r.bytes))",
                          systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
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

    /// "4032 × 3024", or "4032 × 3024 → 3024 × 4032" once a turn is chosen.
    private func sizeText(_ item: RotateImagesModel.Item) -> String {
        let to = model.outputSize(for: item.size)
        let from = "\(item.size.width) × \(item.size.height)"
        return to == item.size ? from : "\(from) → \(to.width) × \(to.height)"
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
                row("Rotate") {
                    iconButton("rotate.left", "Rotate Left") { model.rotateLeft() }
                    iconButton("rotate.right", "Rotate Right") { model.rotateRight() }
                }
                Divider()
                row("Flip") {
                    iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip Horizontal") { model.flipHorizontal() }
                    iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip Vertical") { model.flipVertical() }
                }
                Divider()
                HStack {
                    Text("Result").font(.callout)
                    Spacer(minLength: 4)
                    Text(model.settings.summary).font(.callout).foregroundStyle(.secondary)
                }
                .frame(height: 38)
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isRunning)
            HStack(alignment: .top) {
                Text("The same change is applied to every image.").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Reset") { model.reset() }
                    .buttonStyle(.link).font(.caption2).disabled(model.settings.isIdentity || model.isRunning)
            }
            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ controls: () -> Content) -> some View {
        HStack(spacing: 6) { Text(title).font(.callout); Spacer(minLength: 4); controls() }.frame(height: 38)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18) }
            .buttonStyle(.bordered).controlSize(.small)
            .help(label).accessibilityLabel(label)
    }

    @ViewBuilder private var footer: some View {
        if model.isRunning {
            HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancel() } }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if model.doneCount > 0 && !model.hasPending {
                    Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                    Text("Originals are untouched.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Rotate") { model.rotate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRotate)
                }
            }
        }
    }
}
