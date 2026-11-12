import SwiftUI

struct TopBar: View {
    @Environment(AppState.self) private var state

    private var selectedCategory: ToolCategory? {
        switch state.page {
        case .home, .models, .vault: nil
        case .category(let c): c
        case .tool(let t): t.category
        }
    }

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 12) {
            if case .tool(let t) = state.page {
                Button { state.page = .category(t.category) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .help("Back to \(t.category.rawValue)")
            }
            Spacer()
            HStack(spacing: 2) {
                pill("All", active: state.page == .home) { state.page = .home }
                ForEach(ToolCategory.allCases) { c in
                    pill(c.rawValue, active: selectedCategory == c) { state.page = .category(c) }
                }
                pill("AI Models", active: state.page == .models) { state.page = .models }
                pill("Vault", active: state.page == .vault) { state.page = .vault }
            }
            .padding(3)
            .background(Capsule().fill(Theme.tint.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Theme.stroke))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tools", text: $state.search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(width: 200)
            .background(Capsule().fill(Theme.tint.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Theme.stroke))
            Button { state.isDark.toggle() } label: {
                Image(systemName: state.isDark ? "sun.max" : "moon")
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.tint.opacity(0.05)))
                    .overlay(Circle().strokeBorder(Theme.stroke))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(state.isDark ? "Switch to light mode" : "Switch to dark mode")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func pill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(Capsule().fill(active ? Theme.tint.opacity(0.14) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
