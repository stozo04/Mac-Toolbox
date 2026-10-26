import Foundation
import Observation

@MainActor @Observable
final class PresentationModeModel {
    static let shared = PresentationModeModel()

    static let desktopIcons = DefaultsKey(domain: "com.apple.finder", name: "CreateDesktop")
    static let dockAutohide = DefaultsKey(domain: "com.apple.dock", name: "autohide")
    private static let savedKey = "presentationMode.saved"

    private(set) var isOn = false

    private let store: DefaultsStore
    private let restarter: ProcessRestarter
    private let awake: SleepPreventer
    private let saved: UserDefaults

    init(store: DefaultsStore = SystemDefaults.shared, restarter: ProcessRestarter = SystemProcessRestarter(),
         awake: SleepPreventer = PowerAssertions(), saved: UserDefaults = .standard) {
        self.store = store
        self.restarter = restarter
        self.awake = awake
        self.saved = saved
        // Toolbox was quit while presenting: the settings are still switched, so offer to switch them back.
        if saved.dictionary(forKey: Self.savedKey) != nil {
            isOn = true
            awake.hold(keepDisplayOn: true, reason: "Toolbox Presentation Mode")
        }
    }

    func turnOn() {
        guard !isOn else { return }
        // What was there before, so turning off puts everything back exactly (a missing entry = the key was not set).
        var previous: [String: Bool] = [:]
        if let desktop = storedBool(Self.desktopIcons) { previous["desktop"] = desktop }
        if let autohide = storedBool(Self.dockAutohide) { previous["autohide"] = autohide }
        saved.set(previous, forKey: Self.savedKey)
        store.set(false, for: Self.desktopIcons)
        store.set(true, for: Self.dockAutohide)
        restarter.restart([.finder, .dock])
        awake.hold(keepDisplayOn: true, reason: "Toolbox Presentation Mode")
        isOn = true
        Log.info("Presentation mode on", category: "presentation")
    }

    func turnOff() {
        guard isOn else { return }
        let previous = saved.dictionary(forKey: Self.savedKey) ?? [:]
        store.set(previous["desktop"] as? Bool, for: Self.desktopIcons)
        store.set(previous["autohide"] as? Bool, for: Self.dockAutohide)
        saved.removeObject(forKey: Self.savedKey)
        restarter.restart([.finder, .dock])
        awake.release()
        isOn = false
        Log.info("Presentation mode off", category: "presentation")
    }

    func toggle() {
        if isOn { turnOff() } else { turnOn() }
    }

    private func storedBool(_ key: DefaultsKey) -> Bool? {
        guard let value = store.value(for: key) as? NSNumber else { return nil }
        return value.boolValue
    }
}
