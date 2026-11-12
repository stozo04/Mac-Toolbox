import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(VaultModel.self) private var vault

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Group {
                if !state.search.isEmpty {
                    SearchResultsView()
                } else {
                    switch state.page {
                    case .home: HomeView()
                    case .category(let c): CategoryView(category: c)
                    case .models: ModelsView()
                    case .vault: VaultView()
                    case .tool(let t): ToolView(tool: t).id(t.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Own row so it never covers a tool's buttons in the bottom-right corner.
            HStack {
                Spacer()
                VersionBadge()
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
        .background(Theme.background)
        .onChange(of: state.page) { old, _ in
            if old == .vault { Task { await vault.lock() } }
        }
    }
}
