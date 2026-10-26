import AppKit
import ApplicationServices

/// Stops key presses from reaching any app while it is on.
protocol KeyboardBlocker: AnyObject {
    var isBlocking: Bool { get }
    /// False when macOS has not given Toolbox permission to watch the keyboard.
    func start() -> Bool
    func stop()
}

enum AccessibilityAccess {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt, which leads to the right page in System Settings.
    static func prompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

final class EventTapKeyboardBlocker: KeyboardBlocker {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isBlocking: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        guard AccessibilityAccess.isGranted else { return false }
        // Key down/up, modifier keys, and the media/brightness keys (system-defined events, type 14).
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, CGEventType(rawValue: 14)!]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // macOS switches a tap off if it is slow; switch it straight back on so the keyboard stays paused.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon { CGEvent.tapEnable(tap: Unmanaged<EventTapKeyboardBlocker>.fromOpaque(refcon).takeUnretainedValue().tap!, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return nil // swallow the key
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                              callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = created
        source = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    deinit { stop() }
}
