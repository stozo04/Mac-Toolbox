import SwiftUI
import UniformTypeIdentifiers

struct VaultLibraryView: View {
    @Environment(VaultModel.self) private var vault
    @State private var selecting = false
    @State private var confirmingDelete: Set<VaultItem.ID> = []
    @State private var dropTargeted = false
    @State private var changingPassword = false

    private static let tileMinimum: CGFloat = 150
    private static let tileMaximum: CGFloat = 230
    private static let spacing: CGFloat = 10

    var body: some View {
        @Bindable var vault = vault
        VStack(spacing: 12) {
            header
            if !vault.items.isEmpty { VaultSearchBar() }
            if let progress = vault.moveProgress { MoveProgressBar(progress: progress) }
            if !vault.moveFailures.isEmpty { failures }
            if let message = vault.message { banner(message) }
            content
        }
        .padding(.horizontal, 24).padding(.top, 8)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .overlay { if vault.viewing != nil { VaultViewer() } }
        .onDeleteCommand { if !vault.selection.isEmpty { confirmingDelete = vault.selection } }
        .confirmationDialog(deleteTitle, isPresented: deleteDialogShown, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let ids = confirmingDelete
                Task { await vault.delete(ids) }
            }
        } message: {
            Text("They're deleted for good, not moved to the Trash. This can't be undone.")
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.open.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Vault").font(.title2.weight(.semibold))
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if selecting || !vault.selection.isEmpty {
                if !vault.selection.isEmpty {
                    Button(role: .destructive) { confirmingDelete = vault.selection } label: {
                        Label("Delete \(vault.selection.count)", systemImage: "trash")
                    }
                }
                Button("Done") {
                    selecting = false
                    vault.selection = []
                }
            } else {
                Button("Select") { selecting = true }.disabled(vault.items.isEmpty)
            }
            Button(action: chooseFiles) { Label("Add", systemImage: "plus") }
                .disabled(vault.moveProgress != nil)
            Menu {
                Button("Change password…") { changingPassword = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            Button { Task { await vault.lock() } } label: { Label("Lock", systemImage: "lock.fill") }
                .buttonStyle(.borderedProminent)
                .tint(Theme.warning)
        }
        .controlSize(.large)
    }

    @ViewBuilder private var content: some View {
        if !vault.query.isEmpty, let result = vault.searchResult, !vault.items.isEmpty {
            searchSummary(result)
        }
        if vault.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Your vault is empty").font(.title3.weight(.semibold))
                Text("Drag photos and videos here, or click Add. They're moved in, not copied: each original is deleted once its copy in the vault has been checked.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinimum, maximum: Self.tileMaximum), spacing: Self.spacing)],
                          spacing: Self.spacing) {
                    ForEach(vault.displayedItems) { item in
                        VaultTile(item: item, selected: vault.selection.contains(item.id))
                            .onTapGesture { tap(item) }
                            .contextMenu {
                                Button("Delete", role: .destructive) { confirmingDelete = [item.id] }
                            }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder private func searchSummary(_ result: VaultSearchResult) -> some View {
        let count = vault.displayedItems.count
        Group {
            if count == 0 {
                Text("No matches for “\(vault.query)”")
            } else if !result.strong {
                Text("No close matches. These are the nearest:")
            } else {
                Text(count == 1 ? "1 match" : "\(count) matches")
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failures: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(vault.moveFailures.count == 1 ? "1 file wasn't moved in" : "\(vault.moveFailures.count) files weren't moved in",
                      systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.semibold)).foregroundStyle(.orange)
                Spacer()
                Button { vault.moveFailures = [] } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            ForEach(vault.moveFailures.prefix(5)) { failure in
                Text("\(failure.name): \(failure.reason)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if vault.moveFailures.count > 5 {
                Text("and \(vault.moveFailures.count - 5) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).cardBackground(corner: 12)
    }

    private func banner(_ message: String) -> some View {
        HStack {
            Text(message).font(.callout).foregroundStyle(.red)
            Spacer()
            Button { vault.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12).cardBackground(corner: 12)
    }

    private var summary: String {
        let count = vault.items.count
        let size = ByteCountFormatter.string(fromByteCount: vault.totalBytes, countStyle: .file)
        return count == 1 ? "1 item, \(size)" : "\(count) items, \(size)"
    }

    private var deleteTitle: String {
        confirmingDelete.count == 1 ? "Delete 1 item?" : "Delete \(confirmingDelete.count) items?"
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { !confirmingDelete.isEmpty }, set: { if !$0 { confirmingDelete = [] } })
    }

    private func tap(_ item: VaultItem) {
        let modifiers = NSEvent.modifierFlags
        if selecting || modifiers.contains(.command) || modifiers.contains(.shift) {
            if vault.selection.contains(item.id) { vault.selection.remove(item.id) } else { vault.selection.insert(item.id) }
        } else {
            vault.viewing = item.id
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .movie, .folder]
        panel.prompt = "Move into vault"
        panel.message = "The files you choose are moved into the vault and the originals are deleted."
        guard panel.runModal() == .OK else { return }
        vault.add(panel.urls)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let collected = URLCollector()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { vault.add(collected.urls) }
        return true
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func add(_ url: URL) { lock.lock(); stored.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
}

private struct MoveProgressBar: View {
    let progress: VaultModel.MoveProgress

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            Text("Moving \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct VaultTile: View {
    @Environment(VaultModel.self) private var vault
    let item: VaultItem
    let selected: Bool
    @State private var thumbnail: CGImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                } else {
                    Theme.inset.overlay(ProgressView().controlSize(.small))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                        if let start = vault.matchStart(for: item) { Text(VaultTime.label(start)).monospacedDigit() }
                    }
                    .font(.caption).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.6))).padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent).padding(8)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 3 : 1)
            }
            .contentShape(Rectangle())
            .help(item.name)
            .task(id: item.id) { thumbnail = await vault.thumbnails?.image(for: item) }
    }
}

private struct ChangePasswordSheet: View {
    @Environment(VaultModel.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var again = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change vault password").font(.headline)
            SecureField("Current password", text: $current)
            SecureField("New password", text: $new)
            SecureField("New password again", text: $again)
            if let message = vault.message { Text(message).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change") {
                    working = true
                    Task {
                        if await vault.changePassword(current: current, new: new, confirmation: again) {
                            vault.message = nil
                            dismiss()
                        }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 340)
        .onAppear { vault.message = nil }
    }
}
