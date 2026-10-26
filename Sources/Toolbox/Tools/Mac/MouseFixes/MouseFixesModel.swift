import AppKit
import Observation

@MainActor @Observable
final class MouseFixesModel {
    static let shared = MouseFixesModel()
    private static let key = "mouseFixes.settings"

    enum Status: Equatable {
        case off
        case on
        case needsPermission
    }

    var settings: ScrollSettings {
        didSet { if settings != oldValue { apply() } }
    }
    private(set) var status = Status.off

    private let tap: ScrollTapping
    private let defaults: UserDefaults

    init(tap: ScrollTapping? = nil, defaults: UserDefaults = .standard) {
        self.tap = tap ?? ScrollEventTap()
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(ScrollSettings.self, from: data) {
            settings = saved
        } else {
            settings = ScrollSettings()
        }
    }

    /// Turns the saved fixes back on when Toolbox starts.
    func restoreOnLaunch() { apply() }

    func recheckPermission() { if status == .needsPermission { apply() } }

    private func apply() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
        tap.settings = settings
        guard settings.isActive else {
            tap.stop()
            status = .off
            return
        }
        if tap.isRunning || tap.start() {
            status = .on
            Log.info("Mouse fixes on", category: "mousefixes", ["reverse": String(settings.reverse), "smooth": String(settings.smooth)])
        } else {
            status = .needsPermission
            AccessibilityAccess.prompt()
        }
    }
}
