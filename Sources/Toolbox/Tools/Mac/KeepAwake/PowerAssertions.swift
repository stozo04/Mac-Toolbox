import Foundation
import IOKit.pwr_mgt
import IOKit.ps

/// Holds the IOKit power assertions that stop the Mac from sleeping.
protocol SleepPreventer: AnyObject {
    var isHeld: Bool { get }
    /// Replaces any assertion already held.
    func hold(keepDisplayOn: Bool, reason: String)
    func release()
}

final class PowerAssertions: SleepPreventer {
    private var system: IOPMAssertionID = 0
    private var display: IOPMAssertionID = 0
    private var heldReason: String?
    private(set) var isHeld = false

    /// Changes only what differs, and creates any new assertion before dropping an old one. A moment with no
    /// assertion is enough for macOS to sleep the display or the Mac when the user has been idle past the sleep setting.
    func hold(keepDisplayOn: Bool, reason: String) {
        let renamed = reason != heldReason
        var stale: [IOPMAssertionID] = []
        // Idle system sleep is always prevented; the display only when asked, so the screen can still turn off.
        if renamed || system == 0 {
            if system != 0 { stale.append(system) }
            system = create("PreventUserIdleSystemSleep", reason)
        }
        if keepDisplayOn {
            if renamed || display == 0 {
                if display != 0 { stale.append(display) }
                display = create("PreventUserIdleDisplaySleep", reason)
            }
        } else if display != 0 {
            stale.append(display)
            display = 0
        }
        for id in stale { IOPMAssertionRelease(id) }
        heldReason = reason
        // Only true when everything asked for exists, so a refused assertion is retried on the next refresh.
        isHeld = system != 0 && (!keepDisplayOn || display != 0)
    }

    func release() {
        if system != 0 { IOPMAssertionRelease(system); system = 0 }
        if display != 0 { IOPMAssertionRelease(display); display = 0 }
        heldReason = nil
        isHeld = false
    }

    private func create(_ type: String, _ reason: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        guard result == kIOReturnSuccess else {
            Log.warning("Power assertion was not created", category: "keepawake", ["type": type, "code": String(result)])
            return 0
        }
        return id
    }

    deinit { release() }
}

enum PowerSource {
    /// True when the Mac is running from the wall (always true on a desktop Mac).
    static var isOnPowerAdapter: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type != kIOPMBatteryPowerKey
    }

    /// Calls `onChange` whenever the power source changes. Keep the returned object alive; drop it to stop.
    @MainActor static func observe(_ onChange: @escaping @MainActor () -> Void) -> AnyObject {
        let box = Observer(onChange)
        let context = Unmanaged.passUnretained(box).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let box = Unmanaged<Observer>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { box.handler() } }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            box.source = source
        }
        return box
    }

    final class Observer {
        let handler: @MainActor () -> Void
        var source: CFRunLoopSource?
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
        deinit { if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) } }
    }
}
