import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var state

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ToolCatalog.all.count) tools").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        (Text("Every tool, ") + Text("right on your Mac.").foregroundStyle(.secondary))
                            .font(.system(size: 34, weight: .bold))
                        Spacer()
                        RecentChips()
                    }
                }

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(ToolCategory.allCases) { c in
                        CategoryCard(category: c)
                    }
                    FavoritesCard()
                }
            }
            .padding(20)
        }
    }
}

private struct CategoryCard: View {
    @Environment(AppState.self) private var state
    let category: ToolCategory

    var body: some View {
        let tools = ToolCatalog.tools(in: category)
        Button { state.page = .category(category) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: category.symbol).foregroundStyle(Theme.accent)
                    Text(category.rawValue).font(.title3.bold())
                    Text("\(tools.count) tools").font(.caption).foregroundStyle(.secondary)
                }
                Text(category.summary).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach(tools.prefix(4)) { Text($0.name).font(.callout) }
                if tools.count > 4 {
                    Text("\(tools.count - 4) more").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .padding(18)
            .cardBackground()
        }
        .buttonStyle(.plain)
    }
}

private struct FavoritesCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Favorites").font(.title3.bold())
                Text("\(state.favoriteTools.count)").foregroundStyle(.secondary)
            }
            if state.favoriteTools.isEmpty {
                Text("Star a tool to pin it here.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(state.favoriteTools) { t in
                Button(t.name) { state.open(t) }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .padding(18)
        .cardBackground()
    }
}

struct RecentChips: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if !state.recentTools.isEmpty {
            HStack(spacing: 8) {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                ForEach(state.recentTools) { t in
                    Button { state.open(t) } label: {
                        Label(t.name, systemImage: t.symbol).font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.tint.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
