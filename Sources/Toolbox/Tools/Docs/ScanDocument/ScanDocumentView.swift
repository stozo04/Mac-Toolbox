import SwiftUI
import UniformTypeIdentifiers

struct ScanDocumentView: View {
    @State private var model = ScanDocumentModel.shared
    @State private var camera = ContinuityBridge()
    @State private var targeted = false
    @State private var confirmClear = false
    @State private var previewing: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if model.hasPages || model.isAdding { pagesCard } else { empty }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted, perform: drop)
            VStack(spacing: 14) {
                options
                summary.frame(height: 172)
            }
            .frame(width: 240)
        }
        .background(ContinuityAnchor(bridge: camera) { model.enqueue($0) })
        .confirmationDialog("Remove all pages?", isPresented: $confirmClear) {
            Button("Remove All Pages", role: .destructive) { model.clear() }
        } message: {
            Text("The scanned pages are discarded. Your photos stay where they are.")
        }
        .sheet(item: $previewing) { id in PagePreview(model: model, id: id) }
    }

    // MARK: Empty state

    private var empty: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(targeted ? Theme.accent : Theme.tint.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
            VStack(spacing: 10) {
                Image(systemName: "doc.viewfinder").font(.system(size: 26))
                    .frame(width: 54, height: 54)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Drop Photos of Paper Here").font(.headline)
                Text("Or scan pages with your iPhone. Each page is found, straightened and cleaned up.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                HStack {
                    Button { scanWithPhone() } label: { Label("Scan with iPhone", systemImage: "iphone") }
                        .buttonStyle(.borderedProminent)
                    Button("Choose Photos...") { choosePhotos() }
                }
                Text("Your iPhone and Mac need to be signed in to the same Apple Account.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let notice = model.notice { noticeLabel(notice) }
                Label("Processed on this Mac. Originals stay untouched.", systemImage: "lock.fill")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    // MARK: Pages

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 18, alignment: .top)]

    private var pagesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Pages").font(.headline)
                Text("\(model.pages.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { scanWithPhone() } label: { Label("Scan More...", systemImage: "iphone") }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                Button { choosePhotos() } label: { Label("Add Photos...", systemImage: "plus") }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                Button { confirmClear = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.small)
                    .help("Remove all pages")
                    .disabled(model.isSaving)
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(model.pages) { page in
                        ScanPageTile(number: model.number(of: page.id), thumbnail: model.thumbnails[page.id], foundEdges: page.foundEdges,
                                     rotate: { model.rotate(page.id, by: $0) },
                                     remove: { model.remove(page.id) },
                                     open: { previewing = page.id },
                                     drop: { model.move($0, to: page.id) },
                                     dragID: page.id.uuidString)
                    }
                    if model.isAdding {
                        VStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                                .frame(width: 100, height: 140)
                                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text("Finding page…").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if let notice = model.notice { noticeLabel(notice) }
            if model.uncroppedCount > 0, !model.isAdding {
                Label("\(model.uncroppedCount == 1 ? "One page" : "\(model.uncroppedCount) pages") had no clear edges, so the whole photo is used.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(corner: 24)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.accent, lineWidth: targeted ? 2 : 0))
    }

    private func noticeLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan").font(.headline)
            Text("Applies to every page.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                row("Look") {
                    Picker("", selection: $model.settings.look) {
                        ForEach(ScanLook.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).buttonStyle(.borderless).fixedSize()
                }
                Divider()
                row("Page size") {
                    Picker("", selection: $model.settings.pageSize) {
                        ForEach(ScanPageSize.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).buttonStyle(.borderless).fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(model.isSaving)
            Text(model.settings.look.blurb).font(.caption2).foregroundStyle(.secondary)
            row("Make text searchable") { Toggle("", isOn: $model.settings.makeSearchable).labelsHidden().toggleStyle(.switch) }
                .padding(.horizontal, 10)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(model.isSaving)
            Text("Adds an invisible layer of the text Toolbox reads on each page, so you can search, select and copy it.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack { Text(title).font(.callout).fixedSize(); Spacer(minLength: 4); control() }.frame(height: 38)
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pages").font(.caption).foregroundStyle(.secondary)
            Text("\(model.pages.count)").font(.system(size: 38, weight: .bold)).monospacedDigit()
            if let saved = model.saved {
                HStack(spacing: 6) {
                    Label("Saved · \(MediaFormat.bytes(saved.bytes))", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green).lineLimit(1)
                    Spacer(minLength: 0)
                    RevealButton { model.reveal(saved.url) }
                }
            } else if model.isSaving {
                Text("Writing page \(min(model.savedPages + 1, model.pages.count)) of \(model.pages.count)…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Drag pages to reorder. Hover a page to rotate or remove it.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if model.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save PDF") { model.save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasPages || model.isAdding)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    // MARK: Adding

    private func scanWithPhone() { camera.showMenu(choosePhotos: choosePhotos) }

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .pdf]
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.add([url]) } }
            }
        }
        return accepted
    }
}

extension UUID: @retroactive Identifiable { public var id: UUID { self } }

/// One page in the grid: its picture, its number, and rotate and remove buttons that appear under the pointer.
private struct ScanPageTile: View {
    let number: Int
    let thumbnail: CGImage?
    let foundEdges: Bool
    let rotate: (Int) -> Void
    let remove: () -> Void
    let open: () -> Void
    let drop: (UUID) -> Void
    let dragID: String

    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                picture
                if hovering {
                    HStack(spacing: 6) {
                        overlayButton("rotate.right", help: "Rotate") { rotate(1) }
                        overlayButton("xmark", help: "Remove page") { remove() }
                    }
                    .padding(6)
                }
            }
            .frame(height: 176)
            Text("\(number)").font(.caption).monospacedDigit()
        }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: open)
        .draggable(dragID)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            drop(id)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Rotate Right") { rotate(1) }
            Button("Rotate Left") { rotate(-1) }
            Divider()
            Button("Remove Page", role: .destructive, action: remove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(number)")
    }

    @ViewBuilder private var picture: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(targeted ? Theme.accent : Theme.stroke, lineWidth: targeted ? 2 : 1))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        } else {
            ProgressView().controlSize(.small)
                .frame(width: 100, height: 140)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func overlayButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A page at a size where its text can be read.
private struct PagePreview: View {
    let model: ScanDocumentModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .overlay(Rectangle().strokeBorder(Theme.stroke))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("Page \(model.number(of: id))").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 640, height: 780)
        .task(id: id) { image = await model.preview(of: id) }
    }
}
