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
    private(set) var isHeld = false

    func hold(keepDisplayOn: Bool, reason: String) {
        release()
        // Idle system sleep is always prevented; the display only when asked, so the screen can still turn off.
        IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    reason as CFString, &system)
        if keepDisplayOn {
            IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        reason as CFString, &display)
        }
        isHeld = true
    }

    func release() {
        if system != 0 { IOPMAssertionRelease(system); system = 0 }
        if display != 0 { IOPMAssertionRelease(display); display = 0 }
        isHeld = false
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
