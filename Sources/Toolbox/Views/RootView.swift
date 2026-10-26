import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

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
                    case .tool(let t): ToolView(tool: t).id(t.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }
}
