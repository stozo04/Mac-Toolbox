import AppKit
import Observation

@MainActor @Observable
final class DisplayControlModel {
    static let shared = DisplayControlModel()
    private static let restoreKey = "displayControl.restore"
    private static let savedKey = "displayControl.saved"

    struct Monitor: Identifiable {
        let id: CGDirectDisplayID
        let uuid: String
        let name: String
        let detail: String
        var bus: AVServiceBus?
        /// Controls the monitor answered for, with the monitor's own maximum for each.
        var maxima: [DDC.Control: Int] = [:]
        var values: [DDC.Control: Double] = [:]
        var problem: String?
        var isControllable: Bool { !maxima.isEmpty }
    }

    private(set) var monitors: [Monitor] = []
    private(set) var isLoading = false
    var selectedID: CGDirectDisplayID?
    var restoreOnOpen: Bool {
        didSet { defaults.set(restoreOnOpen, forKey: Self.restoreKey) }
    }

    private let defaults: UserDefaults
    private var pendingWrites: [String: Task<Void, Never>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.restoreOnOpen = defaults.bool(forKey: Self.restoreKey)
    }

    /// The monitor chosen in the list; before a choice, the first one that can be controlled.
    var selected: Monitor? { monitors.first { $0.id == selectedID } ?? monitors.first { $0.isControllable } ?? monitors.first }

    // MARK: Finding monitors

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            monitors = await Self.discover()
            if !monitors.contains(where: { $0.id == selectedID }) { selectedID = nil }
            isLoading = false
        }
    }

    static func discover() async -> [Monitor] {
        let externals = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID, CGDisplayIsBuiltin(id) == 0 else { return nil }
            return (id, screen)
        }
        let buses = AVServiceBus.isAvailable ? AVServiceBus.externalBuses() : []
        var result: [Monitor] = []
        for (id, screen) in externals {
            let uuid = (CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()).flatMap { CFUUIDCreateString(nil, $0) as String? } ?? "\(id)"
            let mode = CGDisplayCopyDisplayMode(id)
            let hz = mode.map { Int($0.refreshRate.rounded()) } ?? 0
            let detail = "\(mode?.width ?? Int(screen.frame.width)) × \(mode?.height ?? Int(screen.frame.height))" + (hz > 0 ? " · \(hz) Hz" : "")
            var monitor = Monitor(id: id, uuid: uuid, name: screen.localizedName, detail: detail)
            let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
            let sameModel = externals.filter { CGDisplayVendorNumber($0.0) == vendor && CGDisplayModelNumber($0.0) == model }.count
            monitor.bus = matchBus(vendor: vendor, model: model, buses: buses, sameModelCount: sameModel, externalCount: externals.count)
            if !AVServiceBus.isAvailable {
                monitor.problem = "Display control needs a Mac with Apple silicon."
            } else if let bus = monitor.bus {
                for control in DDC.Control.allCases {
                    if let value = await bus.read(control) {
                        monitor.maxima[control] = value.max
                        monitor.values[control] = DDC.percent(current: value.current, max: value.max)
                    }
                }
                if !monitor.isControllable {
                    monitor.problem = "This monitor doesn't answer DDC/CI. Turn DDC/CI on in the monitor's own menu, or try another cable or port. Some docks and adapters block it."
                }
            } else {
                monitor.problem = "Toolbox couldn't tell which connection belongs to this monitor, so it won't change any settings."
            }
            result.append(monitor)
        }
        return result
    }

    /// The registry's EDID UUID starts with the monitor's vendor ID and its product ID with the bytes swapped,
    /// e.g. vendor 0x10AC, product 0xA0B5 gives "10ACB5A0".
    static func edidPrefix(vendor: UInt32, model: UInt32) -> String {
        String(format: "%04X%02X%02X", vendor & 0xFFFF, model & 0xFF, (model >> 8) & 0xFF)
    }

    /// The position of the connection that belongs to a monitor, or nil when it can't be told for certain: that is
    /// when two monitors are the same model, or none of the connections match.
    static func busIndex(vendor: UInt32, model: UInt32, edidUUIDs: [String?], sameModelCount: Int, externalCount: Int) -> Int? {
        let prefix = edidPrefix(vendor: vendor, model: model)
        let matches = edidUUIDs.indices.filter { edidUUIDs[$0]?.uppercased().hasPrefix(prefix) == true }
        if matches.count == 1 && sameModelCount == 1 { return matches[0] }
        // One monitor and one connection: there is nothing to mix up.
        if externalCount == 1 && edidUUIDs.count == 1 { return 0 }
        return nil
    }

    private static func matchBus(vendor: UInt32, model: UInt32, buses: [(edidUUID: String?, bus: AVServiceBus)],
                                 sameModelCount: Int, externalCount: Int) -> AVServiceBus? {
        busIndex(vendor: vendor, model: model, edidUUIDs: buses.map(\.edidUUID), sameModelCount: sameModelCount, externalCount: externalCount).map { buses[$0].bus }
    }

    // MARK: Changing values

    func set(_ control: DDC.Control, percent: Double, on id: CGDirectDisplayID) {
        guard let i = monitors.firstIndex(where: { $0.id == id }), let max = monitors[i].maxima[control], let bus = monitors[i].bus else { return }
        monitors[i].values[control] = percent
        let key = "\(id).\(control.rawValue)"
        let uuid = monitors[i].uuid
        pendingWrites[key]?.cancel()
        pendingWrites[key] = Task { [weak self] in
            // Dragging a slider sends many values; only the last one is written.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let ok = await bus.write(control, raw: DDC.raw(percent: percent, max: max))
            guard let self else { return }
            if ok { self.remember(control, percent: percent, uuid: uuid) } else { self.fail(id, "The monitor didn't accept the change.") }
        }
    }

    private func fail(_ id: CGDirectDisplayID, _ message: String) {
        if let i = monitors.firstIndex(where: { $0.id == id }) { monitors[i].problem = message }
    }

    // MARK: Remembering

    private func remember(_ control: DDC.Control, percent: Double, uuid: String) {
        var all = defaults.dictionary(forKey: Self.savedKey) as? [String: [String: Double]] ?? [:]
        all[uuid, default: [:]][control.rawValue] = percent
        defaults.set(all, forKey: Self.savedKey)
    }

    /// Puts each monitor back to the values Toolbox last set, if the person asked for that.
    func restoreOnLaunch() {
        guard restoreOnOpen, let saved = defaults.dictionary(forKey: Self.savedKey) as? [String: [String: Double]], !saved.isEmpty else { return }
        Task {
            let found = await Self.discover()
            monitors = found
            selectedID = nil
            for monitor in found {
                for (name, percent) in saved[monitor.uuid] ?? [:] {
                    if let control = DDC.Control(rawValue: name), monitor.maxima[control] != nil { set(control, percent: percent, on: monitor.id) }
                }
            }
            Log.info("Display settings restored", category: "displaycontrol", ["monitors": String(found.count)])
        }
    }
}
