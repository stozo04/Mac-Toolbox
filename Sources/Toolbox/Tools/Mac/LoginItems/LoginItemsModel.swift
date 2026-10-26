import AppKit
import Observation

@MainActor @Observable
final class LoginItemsModel {
    static let shared = LoginItemsModel()

    private(set) var items: [LaunchItem] = []
    private(set) var isLoading = false
    private(set) var errors: [String: String] = [:]
    var search = ""

    private let setEnabled: (Bool, LaunchItem) async throws -> Void
    private let scan: () async -> [LaunchItem]

    init(scan: @escaping () async -> [LaunchItem] = {
             let overrides = await LaunchItems.currentOverrides()
             return await Task.detached { LaunchItems.scan(overrides: overrides) }.value
         },
         setEnabled: @escaping (Bool, LaunchItem) async throws -> Void = { try await LaunchItems.setEnabled($0, item: $1) }) {
        self.scan = scan
        self.setEnabled = setEnabled
    }

    func items(in scope: LaunchItem.Scope) -> [LaunchItem] {
        items.filter { $0.scope == scope && (search.isEmpty || $0.label.localizedCaseInsensitiveContains(search)
                                             || $0.developerText.localizedCaseInsensitiveContains(search)) }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            items = await scan()
            isLoading = false
        }
    }

    func toggle(_ item: LaunchItem, to enabled: Bool) {
        errors[item.id] = nil
        Task {
            do {
                try await setEnabled(enabled, item)
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].isEnabled = enabled }
                Log.info("Launch item toggled", category: "loginitems", ["enabled": String(enabled)])
            } catch {
                errors[item.id] = error.localizedDescription
            }
        }
    }

    func reveal(_ item: LaunchItem) { NSWorkspace.shared.activateFileViewerSelecting([item.plist]) }
}
