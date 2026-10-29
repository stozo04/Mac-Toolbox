import SwiftUI
import Observation

enum Page: Hashable {
    case home
    case category(ToolCategory)
    case models
    case tool(Tool)
}

extension Page {
    /// Short name for logs, e.g. "Video/Trim Video".
    var logName: String {
        switch self {
        case .home: "home"
        case .category(let c): c.rawValue
        case .models: "AI Models"
        case .tool(let t): t.id
        }
    }
}

@Observable
final class AppState {
    var page: Page = .home {
        didSet { if page != oldValue { Log.navigate(to: page.logName) } }
    }
    var search = ""
    var isDark = true
    var favorites: Set<String> = []
    var recents: [String] = []

    /// Debug aid: `--page home | <Category> | <Category>/<Tool>` opens that page at launch.
    init(arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--page"), i + 1 < arguments.count else { return }
        let target = arguments[i + 1]
        if let tool = ToolCatalog.tool(id: target) {
            page = .tool(tool)
        } else if target == "AI Models" {
            page = .models
        } else if let category = ToolCategory(rawValue: target) {
            page = .category(category)
        }
    }

    var searchResults: [Tool] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return ToolCatalog.all.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.tagline.localizedCaseInsensitiveContains(q)
        }
    }

    var recentTools: [Tool] { recents.compactMap(ToolCatalog.tool(id:)) }
    var favoriteTools: [Tool] { ToolCatalog.all.filter { favorites.contains($0.id) } }

    func open(_ tool: Tool) {
        recents.removeAll { $0 == tool.id }
        recents.insert(tool.id, at: 0)
        recents = Array(recents.prefix(4))
        search = ""
        page = .tool(tool)
    }

    func toggleFavorite(_ tool: Tool) {
        if favorites.contains(tool.id) { favorites.remove(tool.id) } else { favorites.insert(tool.id) }
    }
}
