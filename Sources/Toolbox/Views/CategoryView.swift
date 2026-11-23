import SwiftUI

struct CategoryView: View {
    let category: ToolCategory
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        let tools = ToolCatalog.tools(in: category)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(tools.count) \(tools.count == 1 ? "tool" : "tools") · \(category.summary)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(category.rawValue).font(.system(size: 34, weight: .bold))
                        Spacer()
                        RecentChips()
                    }
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(tools) { ToolCard(tool: $0) }
                }
            }
            .padding(20)
        }
    }
}

struct ToolCard: View {
    @Environment(AppState.self) private var state
    let tool: Tool
    @State private var companionURL: URL?

    var body: some View {
        Button { state.open(tool) } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.inset)
                    if case .companionApp = tool.input {
                        CompanionAppIcon(installedURL: companionURL, size: 64)
                    } else {
                        Image(systemName: tool.symbol).font(.system(size: 34)).foregroundStyle(Theme.accent)
                    }
                }
                .frame(height: 110)
                .overlay(alignment: .topTrailing) {
                    if case .companionApp(let app) = tool.input {
                        Image(systemName: "arrow.up.forward.app").font(.caption)
                            .foregroundStyle(.secondary).padding(8)
                            .help("Opens \(app.name)")
                    } else if !tool.isImplemented {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                            .foregroundStyle(Theme.warning).padding(8)
                            .help("Feature not implemented")
                    }
                }
                Text(tool.name).font(.headline)
                Text(tool.tagline).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .padding(12)
            .cardBackground()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(state.favorites.contains(tool.id) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(tool) }
        }
        .task(id: tool.id) {
            if case .companionApp(let app) = tool.input { companionURL = state.companionApps.installedURL(of: app) }
        }
    }
}

struct SearchResultsView: View {
    @Environment(AppState.self) private var state
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        ScrollView {
            if state.searchResults.isEmpty {
                ContentUnavailableView.search(text: state.search).padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(state.searchResults) { ToolCard(tool: $0) }
                }
                .padding(20)
            }
        }
    }
}
