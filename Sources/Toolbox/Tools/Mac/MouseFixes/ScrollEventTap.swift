import AppKit
import ApplicationServices

/// Watches scroll events and rewrites the ones from a mouse wheel. Trackpad and Magic Mouse scrolls are
/// "continuous" events and are always passed through untouched.
@MainActor
protocol ScrollTapping: AnyObject {
    var isRunning: Bool { get }
    var settings: ScrollSettings { get set }
    func start() -> Bool
    func stop()
}

@MainActor
final class ScrollEventTap: ScrollTapping {
    /// Stamped on the events Toolbox posts itself so they are not changed twice.
    private static let marker: Int64 = 0x544F4F4C // "TOOL"

    var settings = ScrollSettings()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var smoother = SmoothScroller()
    private var timer: Timer?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        guard AccessibilityAccess.isGranted else { return false }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<ScrollEventTap>.fromOpaque(refcon).takeUnretainedValue()
            // The tap runs on the main run loop, so this is already on the main thread.
            return MainActor.assumeIsolated { owner.handle(type: type, event: event) }
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
        timer?.invalidate()
        timer = nil
        smoother.clear()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 // a wheel, not a trackpad
        else { return Unmanaged.passUnretained(event) }

        let dy = ScrollTransform.lines(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), settings: settings)
        let dx = ScrollTransform.lines(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), settings: settings)

        if settings.smooth {
            smoother.add(dx: dx * ScrollTransform.pixelsPerLine, dy: dy * ScrollTransform.pixelsPerLine)
            startTimer()
            return nil // the glide replaces this click
        }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: ScrollTransform.wholeLines(dy))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: ScrollTransform.wholeLines(dx))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64((dy * ScrollTransform.pixelsPerLine).rounded()))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64((dx * ScrollTransform.pixelsPerLine).rounded()))
        return Unmanaged.passUnretained(event)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
    }

    private func frame() {
        guard let step = smoother.tick() else {
            if smoother.isIdle { timer?.invalidate(); timer = nil }
            return
        }
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: step.dy, wheel2: step.dx, wheel3: 0) {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    deinit { MainActor.assumeIsolated { stop() } }
}
