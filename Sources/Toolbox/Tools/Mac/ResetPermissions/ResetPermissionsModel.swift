import AppKit
import Observation

@MainActor @Observable
final class ResetPermissionsModel {
    static let shared = ResetPermissionsModel()

    enum Status: Equatable {
        case done
        case working
        case failed(String)
    }

    private(set) var apps: [InstalledApp] = []
    private(set) var results: [String: Status] = [:]
    var selected: InstalledApp? { didSet { if selected != oldValue { results = [:] } } }
    var search = ""

    private let reset: (String, String) async throws -> Void

    init(reset: @escaping (String, String) async throws -> Void = { try await PermissionResetter.reset(service: $0, bundleID: $1) }) {
        self.reset = reset
    }

    var filtered: [InstalledApp] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }

    func loadApps() {
        guard apps.isEmpty else { return }
        Task.detached {
            let found = PermissionResetter.installedApps()
            await MainActor.run { self.apps = found }
        }
    }

    func choose(url: URL) {
        guard let app = PermissionResetter.app(at: url) else { return }
        selected = app
    }

    func reset(_ service: PrivacyService) { run(serviceID: service.id) }
    func resetAll() { run(serviceID: "All") }

    private func run(serviceID: String) {
        guard let app = selected else { return }
        results[serviceID] = .working
        Task {
            do {
                try await reset(serviceID, app.bundleID)
                if selected == app { results[serviceID] = .done }
                Log.info("Permission reset", category: "permissions", ["service": serviceID])
            } catch {
                if selected == app { results[serviceID] = .failed(error.localizedDescription) }
                Log.warning("Permission reset failed", category: "permissions", Log.details(error, ["service": serviceID, "app": app.bundleID]))
            }
        }
    }
}
