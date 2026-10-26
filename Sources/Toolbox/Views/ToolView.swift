import SwiftUI

/// Shell shared by every tool: header with favorite star, then the tool's workspace.
/// Real tool UIs replace `ToolWorkspace` per tool; see features/<Category>/<Tool>/README.md.
struct ToolView: View {
    @Environment(AppState.self) private var state
    let tool: Tool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: tool.symbol).font(.title3)
                    .frame(width: 40, height: 40)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(tool.category.rawValue) · \(tool.tagline)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        Text(tool.name).font(.system(size: 26, weight: .bold))
                        Button { state.toggleFavorite(tool) } label: {
                            Image(systemName: state.favorites.contains(tool.id) ? "star.fill" : "star")
                                .foregroundStyle(state.favorites.contains(tool.id) ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ToolWorkspace(tool: tool)
        }
        .padding(16)
    }
}

struct ToolWorkspace: View {
    let tool: Tool

    var body: some View {
        switch tool.input {
        case .dropFiles(let title, let hint, let symbol):
            DropZone(title: title, hint: hint, symbol: symbol)
        case .link:
            DownloadVideoView()
        case .recordScreen:
            RecordScreenView()
        case .live(let symbol, let idle, let action):
            LiveWorkspace(symbol: symbol, idle: idle, action: action)
        case .text:
            TextWorkspace()
        }
    }
}
