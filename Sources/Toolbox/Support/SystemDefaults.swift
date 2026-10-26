import Foundation

struct DefaultsKey: Hashable {
    let domain: String
    let name: String
}

/// Reads and writes another app's preferences (what the `defaults` command does).
protocol DefaultsStore: AnyObject {
    func value(for key: DefaultsKey) -> Any?
    /// Nil removes the key, so the system falls back to its own default.
    func set(_ value: Any?, for key: DefaultsKey)
}

final class SystemDefaults: DefaultsStore {
    static let shared = SystemDefaults()

    private func domain(_ key: DefaultsKey) -> CFString {
        key.domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : key.domain as CFString
    }

    func value(for key: DefaultsKey) -> Any? {
        CFPreferencesCopyValue(key.name as CFString, domain(key), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    func set(_ value: Any?, for key: DefaultsKey) {
        CFPreferencesSetValue(key.name as CFString, value as CFPropertyList?, domain(key), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain(key), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

/// The system processes that must restart to pick up a changed preference.
enum RestartTarget: String, CaseIterable {
    case dock = "Dock"
    case finder = "Finder"
    case systemUIServer = "SystemUIServer"
}

protocol ProcessRestarter: AnyObject {
    func restart(_ targets: Set<RestartTarget>)
}

final class SystemProcessRestarter: ProcessRestarter {
    func restart(_ targets: Set<RestartTarget>) {
        for target in targets {
            Task { _ = try? await Shell.run("/usr/bin/killall", [target.rawValue]) }
        }
    }
}
