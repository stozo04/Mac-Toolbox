import SwiftUI

struct VaultDetailsSheet: View {
    @Environment(VaultModel.self) private var vault
    @Environment(\.dismiss) private var dismiss
    let item: VaultItem
    @State private var name = ""
    @State private var renameError: String?
    @State private var renaming = false
    @State private var details: VaultFileDetails?
    @State private var status: VaultSearchStatus = .checking

    private static let width: CGFloat = 440
    private static let labelWidth: CGFloat = 120
    private static let statusPoll: Duration = .seconds(2)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VaultTile(item: item, selected: false).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Details").font(.headline)
                    Text(item.name).font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
            renameSection
            Divider()
            infoSection
            Divider()
            searchSection
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: Self.width)
        .task(id: item.id) { await load() }
        .task(id: item.id) { await watchSearch() }
    }

    private var renameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name").font(.callout.weight(.semibold))
            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(rename)
                    .onChange(of: name) { renameError = nil }
                if !item.url.pathExtension.isEmpty {
                    Text(".\(item.url.pathExtension)").foregroundStyle(.secondary)
                }
                Button("Rename", action: rename)
                    .disabled(renaming || name == VaultRename.editableName(of: item))
            }
            if let renameError { Text(renameError).font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var infoSection: some View {
        if let details {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(details.lines) { line in
                    GridRow {
                        Text(line.label).foregroundStyle(.secondary).frame(width: Self.labelWidth, alignment: .leading)
                        Text(line.value).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Smart search").font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Image(systemName: statusSymbol).foregroundStyle(statusColor)
                Text(statusText).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                statusAction
            }
        }
    }

    @ViewBuilder private var statusAction: some View {
        switch status {
        case .notIndexed: Button("Add to Search") { add() }
        case .failed: Button("Try Again") { add() }
        case .needsModel:
            if case .downloading = vault.searchState { ProgressView().controlSize(.small) } else { Button("Download Model") { vault.downloadModel() } }
        case .adding, .checking: ProgressView().controlSize(.small)
        case .indexed, .off: EmptyView()
        }
    }

    private var statusText: String {
        switch status {
        case .checking: "Checking…"
        case .indexed(let picture, let sound):
            switch (picture, sound) {
            case (true, true): "In search: what it shows and what it says."
            case (true, false): item.kind == .video ? "In search: what it shows. No sound to search." : "In search."
            case (false, true): "In search: what it says."
            case (false, false): "In search."
            }
        case .adding: "Being added to search…"
        case .notIndexed: "Not in search yet."
        case .failed: "Couldn't be read for search last time."
        case .needsModel: "Search needs its on-device model (EmbeddingGemma), downloaded once."
        case .off(let reason): reason
        }
    }

    private var statusSymbol: String {
        switch status {
        case .indexed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .notIndexed, .needsModel, .off: "circle.dashed"
        case .adding, .checking: "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch status {
        case .indexed: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private func load() async {
        name = VaultRename.editableName(of: item)
        details = await VaultFileDetails.load(item, playable: await vault.playableURL(for: item))
    }

    private func watchSearch() async {
        while !Task.isCancelled {
            status = await vault.searchStatus(of: item)
            if case .indexed = status { return }
            try? await Task.sleep(for: Self.statusPoll)
        }
    }

    private func add() {
        vault.addToSearch(item)
        status = .adding
    }

    private func rename() {
        guard !renaming else { return }
        renaming = true
        Task {
            defer { renaming = false }
            do {
                _ = try await vault.rename(item, to: name)
            } catch {
                renameError = error.localizedDescription
            }
        }
    }
}
