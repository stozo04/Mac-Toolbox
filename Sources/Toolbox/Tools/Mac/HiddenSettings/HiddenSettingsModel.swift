import Foundation
import Observation

@MainActor @Observable
final class HiddenSettingsModel {
    static let shared = HiddenSettingsModel()

    /// Bumped on every change so views re-read the stored values.
    private(set) var revision = 0

    private let store: DefaultsStore
    private let restarter: ProcessRestarter
    private var pending: Set<RestartTarget> = []
    private var restartTask: Task<Void, Never>?

    init(store: DefaultsStore = SystemDefaults.shared, restarter: ProcessRestarter = SystemProcessRestarter()) {
        self.store = store
        self.restarter = restarter
    }

    // MARK: Reading

    /// The switch as the person sees it, with keys named the opposite way round already flipped.
    func isOn(_ s: HiddenSetting) -> Bool {
        _ = revision
        guard case .toggle(let defaultStored, let inverted) = s.kind else { return false }
        var stored = defaultStored
        if let number = store.value(for: s.key) as? NSNumber { stored = number.boolValue }
        return inverted ? !stored : stored
    }

    /// Seconds, or nil while the system default is in use.
    func number(_ s: HiddenSetting) -> Double? {
        _ = revision
        guard let number = store.value(for: s.key) as? NSNumber else { return nil }
        return number.doubleValue
    }

    func text(_ s: HiddenSetting) -> String {
        _ = revision
        let stored = store.value(for: s.key) as? String
        switch s.kind {
        case .choice(_, let d): return stored ?? d
        case .folder(let d): return stored ?? d
        default: return ""
        }
    }

    /// True when a value is stored that differs from the system default, so a reset arrow can be shown.
    func isModified(_ s: HiddenSetting) -> Bool {
        _ = revision
        guard let raw = store.value(for: s.key) else { return false }
        switch s.kind {
        case .toggle(let d, _):
            guard let number = raw as? NSNumber else { return false }
            return number.boolValue != d
        case .slider:
            return true
        case .choice(_, let d):
            return (raw as? String) != d
        case .folder(let d):
            guard let path = raw as? String else { return false }
            return (path as NSString).expandingTildeInPath != (d as NSString).expandingTildeInPath
        }
    }

    var anyModified: Bool { HiddenSetting.all.contains { isModified($0) } }

    // MARK: Writing

    func setOn(_ on: Bool, _ s: HiddenSetting) {
        guard case .toggle(_, let inverted) = s.kind else { return }
        write(inverted ? !on : on, s)
    }

    func setNumber(_ value: Double, _ s: HiddenSetting) { write((value * 100).rounded() / 100, s) }
    func setText(_ value: String, _ s: HiddenSetting) { write(value, s) }
    func reset(_ s: HiddenSetting) { write(nil, s) }
    func resetAll() { for s in HiddenSetting.all where isModified(s) { write(nil, s) } }

    private func write(_ value: Any?, _ s: HiddenSetting) {
        store.set(value, for: s.key)
        revision += 1
        if let target = s.group.restarts { queueRestart(target) }
        Log.info("Hidden setting changed", category: "hiddensettings", ["setting": s.id])
    }

    /// Several quick changes (a slider drag) restart each process once.
    private func queueRestart(_ target: RestartTarget) {
        pending.insert(target)
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            let targets = pending
            pending = []
            restarter.restart(targets)
        }
    }
}
