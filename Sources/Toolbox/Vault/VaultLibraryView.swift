import SwiftUI
import UniformTypeIdentifiers

struct VaultLibraryView: View {
    @Environment(VaultModel.self) private var vault
    @State private var selecting = false
    @State private var confirmingDelete: Set<VaultItem.ID> = []
    @State private var dropTargeted = false
    @State private var changingPassword = false
    @State private var keeping: (keeper: VaultItem, group: VaultDuplicates.Group)?
    @State private var confirmingEmptyTrash = false

    private static let tileMinimum: CGFloat = 150
    private static let tileMaximum: CGFloat = 230
    private static let spacing: CGFloat = 10

    var body: some View {
        @Bindable var vault = vault
        VStack(spacing: 12) {
            header
            if !vault.items.isEmpty {
                if vault.mode == .library { VaultSearchBar() }
                browseBar
            }
            if !vault.trash.isEmpty { trashBar }
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
        .confirmationDialog(keepTitle, isPresented: keepDialogShown, titleVisibility: .visible) {
            Button("Keep and Move Others to Trash", role: .destructive) {
                guard let keeping else { return }
                Task { await vault.keep(keeping.keeper, in: keeping.group) }
            }
        } message: {
            Text("The other copies go to the vault's own Trash, where they stay encrypted. You can put them back or empty it from the Duplicates view.")
        }
        .confirmationDialog(emptyTrashTitle, isPresented: $confirmingEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { vault.emptyTrash() }
        } message: {
            Text("They're deleted for good. This can't be undone.")
        }
        .onChange(of: vault.mode) { selecting = false }
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
        .sheet(isPresented: detailsShown) {
            if let item = vault.items.first(where: { $0.id == vault.detailing }) { VaultDetailsSheet(item: item) }
        }
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

    private var browseBar: some View {
        @Bindable var vault = vault
        return HStack(spacing: 10) {
            Picker("View", selection: $vault.mode) {
                ForEach(VaultModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Library shows everything; Duplicates finds files that are exact copies of each other")
            Picker("Show", selection: $vault.filter) {
                ForEach(VaultFilter.allCases) { Text($0.tabTitle(in: vault.items)).monospacedDigit().tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if vault.mode == .library && vault.filter == .videos && vault.query.isEmpty {
                Picker("Order", selection: $vault.videoOrder) {
                    ForEach(VaultVideoOrder.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Sort videos by length")
            }
            Spacer()
        }
    }

    @ViewBuilder private var content: some View {
        if vault.mode == .library, !vault.query.isEmpty, let result = vault.searchResult, !vault.items.isEmpty {
            searchSummary(result)
        }
        if vault.mode == .duplicates && !vault.items.isEmpty {
            duplicatesContent
        } else if vault.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Your vault is empty").font(.title3.weight(.semibold))
                Text("Drag photos and videos here, or click Add. They're moved in, not copied: each original is deleted once its copy in the vault has been checked.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vault.query.isEmpty && vault.displayedItems.isEmpty {
            Text(vault.filter.emptyMessage).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinimum, maximum: Self.tileMaximum), spacing: Self.spacing)],
                          spacing: Self.spacing) {
                    if let sections = vault.searchSections, let result = vault.searchResult {
                        if !sections.clear.isEmpty {
                            Section { tiles(sections.clear) } header: { sectionHeader("Best matches") }
                        }
                        if !sections.possible.isEmpty {
                            Section { tiles(sections.possible) } header: { sectionHeader(possibleTitle(result, hasClear: !sections.clear.isEmpty)) }
                        }
                    } else {
                        tiles(vault.displayedItems)
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder private var duplicatesContent: some View {
        if let groups = vault.visibleDuplicateGroups {
            if groups.isEmpty {
                Text(noDuplicatesMessage).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(duplicatesSummary(groups)).font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(groups) { duplicateGroup($0) }
                        }
                        .padding(.bottom, 16)
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking for files that are exact copies…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func duplicateGroup(_ group: VaultDuplicates.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("\(group.copies.count) copies · \(ByteCountFormatter.string(fromByteCount: group.bytesEach, countStyle: .file)) each")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinimum, maximum: Self.tileMaximum), spacing: Self.spacing)],
                      alignment: .leading, spacing: Self.spacing) {
                ForEach(group.copies) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        VaultTile(item: item, selected: false).onTapGesture { vault.viewing = item.id }
                        Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(item.name)
                        Button("Keep This One") { keeping = (item, group) }.controlSize(.small)
                            .disabled(vault.moveProgress != nil)
                    }
                }
            }
        }
    }

    private var detailsShown: Binding<Bool> {
        Binding(get: { vault.detailing != nil }, set: { if !$0 { vault.detailing = nil } })
    }

    private var trashBar: some View {
        HStack(spacing: 10) {
            Label(trashDescription, systemImage: "trash").font(.callout)
            Spacer()
            Button("Put Back All") { vault.putBackTrash() }
            Button("Empty Trash…", role: .destructive) { confirmingEmptyTrash = true }
        }
        .disabled(vault.moveProgress != nil)
        .padding(12).cardBackground(corner: 12)
    }

    private var trashDescription: String {
        let size = ByteCountFormatter.string(fromByteCount: vault.trash.bytes, countStyle: .file)
        return vault.trash.count == 1 ? "1 item in the vault's Trash (\(size))" : "\(vault.trash.count) items in the vault's Trash (\(size))"
    }

    private var emptyTrashTitle: String {
        vault.trash.count == 1 ? "Delete 1 item in the vault's Trash?" : "Delete \(vault.trash.count) items in the vault's Trash?"
    }

    private var noDuplicatesMessage: String {
        switch vault.filter {
        case .all: "No duplicates in the vault"
        case .images: "No duplicate images"
        case .videos: "No duplicate videos"
        }
    }

    private func duplicatesSummary(_ groups: [VaultDuplicates.Group]) -> String {
        let extra = ByteCountFormatter.string(fromByteCount: groups.reduce(0) { $0 + $1.extraBytes }, countStyle: .file)
        let sets = groups.count == 1 ? "1 set of identical files" : "\(groups.count) sets of identical files"
        return "\(sets), \(extra) in extra copies. Pick the copy to keep; the others go to the vault's Trash."
    }

    private var keepTitle: String {
        guard let keeping else { return "" }
        let others = keeping.group.copies.count - 1
        return others == 1 ? "Keep “\(keeping.keeper.name)” and move the other copy to the Trash?"
            : "Keep “\(keeping.keeper.name)” and move the other \(others) copies to the Trash?"
    }

    private var keepDialogShown: Binding<Bool> {
        Binding(get: { keeping != nil }, set: { if !$0 { keeping = nil } })
    }

    private func tiles(_ items: [VaultItem]) -> some View {
        ForEach(items) { item in
            VaultTile(item: item, selected: vault.selection.contains(item.id))
                .onTapGesture { tap(item) }
                .contextMenu {
                    Button("Delete", role: .destructive) { confirmingDelete = [item.id] }
                    Button("Details…") { vault.detailing = item.id }
                }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    private func possibleTitle(_ result: VaultSearchResult, hasClear: Bool) -> String {
        if result.isFallback { return "No close matches. These are the nearest:" }
        return hasClear ? "Might also match" : "Might match"
    }

    @ViewBuilder private func searchSummary(_ result: VaultSearchResult) -> some View {
        let count = vault.displayedItems.count
        Text(count == 0 ? "No matches for “\(vault.query)”" : (count == 1 ? "1 result" : "\(count) results"))
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

    private var summary: String { vault.filter.summary(of: vault.items) }

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
                        if let length = vault.lengthLabel(for: item) { Text(length).monospacedDigit() }
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
