import SwiftUI

struct UninstallAppView: View {
    @State private var model = UninstallAppModel.shared

    var body: some View {
        if let app = model.app {
            VStack(alignment: .leading, spacing: 10) {
                MacCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 48, height: 48)
                            VStack(alignment: .leading) {
                                Text(app.name).font(.title2.weight(.bold))
                                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(ByteFormat.string(model.selectedBytes)).font(.title3.weight(.bold))
                                Text("selected").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        content
                        footer
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                DropZone(title: "Drop an App Here", hint: "Drop an app to remove it together with the files it leaves behind.", symbol: "app.dashed",
                         allowsMultiple: false) { urls in if let url = urls.first { model.load(url) } }
                if let message = model.message { Label(message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.yellow) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .empty, .scanning:
            ProgressView("Looking for leftovers…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .removing:
            ScrollView {
                InsetGroup {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        row(item)
                    }
                }
            }
        case .done(let moved, let bytes, let failures):
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "trash.circle.fill").font(.system(size: 46)).foregroundStyle(.green)
                Text("Moved \(moved) item(s), \(ByteFormat.string(bytes)), to the Trash.").font(.callout)
                Text("Empty the Trash to free the space. Until then you can put things back.").font(.caption).foregroundStyle(.secondary)
                if !failures.isEmpty {
                    Text("Couldn't move: \(failures.joined(separator: ", ")). They may need permission.").font(.caption).foregroundStyle(.red)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ item: Leftover) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.selection.contains(item.url) }, set: { _ in model.toggle(item) }))
                .labelsHidden().disabled(model.phase == .removing)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.isApp ? "The app" : item.place).font(.caption).foregroundStyle(.secondary)
                    switch item.confidence {
                    case .related where !item.isApp: Pill(text: "Related", color: .orange)
                    case .nameOnly: Pill(text: "Same name only", color: .orange)
                    default: EmptyView()
                    }
                }
            }
            Spacer()
            Text(ByteFormat.string(item.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            RevealButton { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red) }
            Spacer()
            Button(isDone ? "Done" : "Choose Another") { model.close() }
            if !isDone {
                Button("Move to Trash") { model.confirmAndRemove() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase != .ready || model.selection.isEmpty)
            }
        }
    }

    private var isDone: Bool { if case .done = model.phase { true } else { false } }
}
