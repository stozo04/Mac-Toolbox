import SwiftUI
import VaultSearch

enum VaultTime {
    static func label(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

struct VaultSearchBar: View {
    @Environment(VaultModel.self) private var vault
    @FocusState private var focused: Bool

    private static let downloadMegabytes = Int((Double(EmbeddingModel.totalBytes) / 1_000_000).rounded())

    var body: some View {
        @Bindable var vault = vault
        HStack(spacing: 12) {
            switch vault.searchState {
            case .needsModel:
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                Text("Smart search needs \(EmbeddingModel.name) (\(Self.downloadMegabytes) MB, downloaded once from Hugging Face). It runs on this Mac; nothing in the vault leaves it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Download") { vault.downloadModel() }
            case .downloading(let fraction):
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                ProgressView(value: fraction)
                Text("Downloading \(EmbeddingModel.name)… \(Int(fraction * 100))%")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            default:
                field($vault.query)
                status
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .cardBackground(corner: 12)
    }

    private func field(_ text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your photos and videos, like “beach at sunset”", text: text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { text.wrappedValue = "" }
            if vault.isSearching {
                ProgressView().controlSize(.small)
            } else if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Clear search")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch vault.searchState {
        case .indexing(let done, let total):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading \(min(done + 1, total)) of \(total)…").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize()
            .help("New photos and videos are read once so search can find them. Search works while this runs.")
        case .ready(let unreadable) where unreadable > 0:
            Label(unreadable == 1 ? "1 file can't be searched" : "\(unreadable) files can't be searched",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize()
                .help("These files couldn't be read for search. They're still in the vault.")
            Button("Retry") { vault.retrySearch() }.controlSize(.small)
        case .failed(let reason):
            Label("Search unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize()
                .help(reason)
            Button("Retry") { vault.retrySearch() }.controlSize(.small)
        default:
            EmptyView()
        }
    }
}
