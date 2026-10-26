import XCTest
@testable import Toolbox

@MainActor
final class FakeBlocker: KeyboardBlocker {
    var allow = true
    private(set) var isBlocking = false
    private(set) var starts = 0
    func start() -> Bool { starts += 1; if allow { isBlocking = true }; return allow }
    func stop() { isBlocking = false }
}

@MainActor
final class FakeOverlay: CleaningOverlay {
    private(set) var shown = false
    func show(model: CleanKeyboardModel) { shown = true }
    func hide() { shown = false }
}

@MainActor
final class CleanKeyboardTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 2_000_000)

    private func make(_ blocker: FakeBlocker, _ overlay: FakeOverlay) -> CleanKeyboardModel {
        CleanKeyboardModel(blocker: blocker, overlay: overlay, now: { self.clock })
    }

    func testStartBlocksShowsOverlayAndStopRestoresEverything() {
        let b = FakeBlocker(), o = FakeOverlay(), m = make(b, o)
        m.seconds = 30
        m.start()
        XCTAssertTrue(b.isBlocking)
        XCTAssertTrue(o.shown)
        XCTAssertEqual(m.remaining(at: clock), 30)
        clock = clock.addingTimeInterval(10)
        XCTAssertEqual(m.remaining(at: clock), 20)
        m.stop()
        XCTAssertFalse(b.isBlocking)
        XCTAssertFalse(o.shown)
        XCTAssertEqual(m.state, .idle)
    }

    func testWithoutPermissionNothingIsBlockedAndItSaysSo() {
        let b = FakeBlocker(), o = FakeOverlay()
        b.allow = false
        let m = make(b, o)
        m.start()
        XCTAssertEqual(m.state, .needsPermission)
        XCTAssertFalse(b.isBlocking)
        XCTAssertFalse(o.shown, "never dim the screen if the keyboard can't be paused")
    }

    func testTheCountdownEndsByItselfAndFreesTheKeyboard() async throws {
        let b = FakeBlocker(), o = FakeOverlay(), m = make(b, o)
        m.seconds = 30
        m.start()
        clock = clock.addingTimeInterval(31)
        for _ in 0..<100 where m.isCleaning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(b.isBlocking)
        XCTAssertFalse(o.shown)
    }

    func testStartingTwiceDoesNotStackAndDurationsAreTheOffered() {
        let b = FakeBlocker(), m = make(b, FakeOverlay())
        m.start()
        m.start()
        XCTAssertEqual(b.starts, 1)
        XCTAssertEqual(CleanKeyboardModel.durations, [30, 60, 120])
        m.stop()
    }

    /// With Accessibility access, a real tap is created and removed within one synchronous step, so no key press can
    /// ever be swallowed; without it, starting refuses cleanly.
    func testRealBlockerCanBeCreatedAndRemovedOrRefusesCleanly() {
        let real = EventTapKeyboardBlocker()
        let started = real.start()
        XCTAssertEqual(started, AccessibilityAccess.isGranted)
        XCTAssertEqual(real.isBlocking, started)
        real.stop()
        XCTAssertFalse(real.isBlocking)
    }

    func testRealScrollTapCanBeCreatedAndRemovedOrRefusesCleanly() {
        let real = ScrollEventTap()
        let started = real.start()
        XCTAssertEqual(started, AccessibilityAccess.isGranted)
        XCTAssertEqual(real.isRunning, started)
        real.stop()
        XCTAssertFalse(real.isRunning)
    }
}

final class ScrollMathTests: XCTestCase {
    func testReverseSpeedAndCombination() {
        XCTAssertEqual(ScrollTransform.lines(3, settings: ScrollSettings()), 3)
        XCTAssertEqual(ScrollTransform.lines(3, settings: ScrollSettings(reverse: true)), -3)
        XCTAssertEqual(ScrollTransform.lines(-2, settings: ScrollSettings(speed: 2.5)), -5)
        XCTAssertEqual(ScrollTransform.lines(2, settings: ScrollSettings(reverse: true, speed: 3)), -6)
        XCTAssertEqual(ScrollTransform.lines(0, settings: ScrollSettings(reverse: true, speed: 3)), 0)
    }

    func testWholeLinesNeverSwallowAClick() {
        XCTAssertEqual(ScrollTransform.wholeLines(0.3), 1)
        XCTAssertEqual(ScrollTransform.wholeLines(-0.3), -1)
        XCTAssertEqual(ScrollTransform.wholeLines(2.6), 3)
        XCTAssertEqual(ScrollTransform.wholeLines(-5), -5)
        XCTAssertEqual(ScrollTransform.wholeLines(0), 0)
    }

    func testIsActiveAndSummary() {
        XCTAssertFalse(ScrollSettings().isActive)
        XCTAssertFalse(ScrollSettings(speed: 1.001).isActive)
        XCTAssertTrue(ScrollSettings(reverse: true).isActive)
        XCTAssertTrue(ScrollSettings(speed: 2).isActive)
        XCTAssertTrue(ScrollSettings(smooth: true).isActive)
        XCTAssertEqual(ScrollSettings(reverse: true, speed: 2, smooth: true).summary, "reversed direction, 2× speed, smooth scrolling")
    }

    func testSmoothScrollDeliversTheExactTotalAndGlidesToAStop() {
        var s = SmoothScroller()
        s.add(dx: 0, dy: 96)
        var steps: [Int] = []
        while let step = s.tick() {
            steps.append(Int(step.dy))
            XCTAssertLessThan(steps.count, 200, "must come to a stop")
        }
        XCTAssertEqual(steps.reduce(0, +), 96, "no distance is lost or invented")
        XCTAssertGreaterThan(steps.count, 8, "spread over several frames")
        XCTAssertEqual(steps.firstIndex(of: steps.max()!)!, 0, "it starts with the biggest step")
        XCTAssertGreaterThan(steps.prefix(4).reduce(0, +), steps.suffix(4).reduce(0, +) * 3, "and tails off")
        XCTAssertTrue(s.isIdle)
    }

    func testSmoothScrollHandlesReverseAndBothAxesAndNewClicksMidGlide() {
        var s = SmoothScroller()
        s.add(dx: 30, dy: -64)
        var x = 0, y = 0
        for i in 0..<5 {
            if let t = s.tick() { x += Int(t.dx); y += Int(t.dy) }
            if i == 2 { s.add(dx: 0, dy: -32) } // another click while gliding
        }
        while let t = s.tick() { x += Int(t.dx); y += Int(t.dy) }
        XCTAssertEqual(x, 30)
        XCTAssertEqual(y, -96)
    }

    func testClearStopsTheGlideAtOnce() {
        var s = SmoothScroller()
        s.add(dx: 0, dy: 500)
        _ = s.tick()
        s.clear()
        XCTAssertNil(s.tick())
        XCTAssertTrue(s.isIdle)
    }
}

@MainActor
final class FakeTap: ScrollTapping {
    var settings = ScrollSettings()
    var allow = true
    private(set) var isRunning = false
    private(set) var startCount = 0
    func start() -> Bool { startCount += 1; if allow { isRunning = true }; return allow }
    func stop() { isRunning = false }
}

@MainActor
final class MouseFixesModelTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "toolbox.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testTurningOnAFixStartsTheTapAndTurningAllOffStopsIt() {
        let tap = FakeTap(), m = MouseFixesModel(tap: tap, defaults: defaults())
        XCTAssertEqual(m.status, .off)
        m.settings.reverse = true
        XCTAssertEqual(m.status, .on)
        XCTAssertTrue(tap.isRunning)
        XCTAssertTrue(tap.settings.reverse)
        m.settings.speed = 2
        XCTAssertEqual(tap.startCount, 1, "changing a setting reuses the running tap")
        XCTAssertEqual(tap.settings.speed, 2)
        m.settings = ScrollSettings()
        XCTAssertEqual(m.status, .off)
        XCTAssertFalse(tap.isRunning)
    }

    func testMissingPermissionIsReportedAndRecovers() {
        let tap = FakeTap(), m = MouseFixesModel(tap: tap, defaults: defaults())
        tap.allow = false
        m.settings.smooth = true
        XCTAssertEqual(m.status, .needsPermission)
        XCTAssertFalse(tap.isRunning)
        tap.allow = true
        m.recheckPermission()
        XCTAssertEqual(m.status, .on)
    }

    func testSettingsSurviveARestartAndAreRestoredOnLaunch() {
        let d = defaults()
        let first = MouseFixesModel(tap: FakeTap(), defaults: d)
        first.settings = ScrollSettings(reverse: true, speed: 3, smooth: true)
        let tap = FakeTap()
        let second = MouseFixesModel(tap: tap, defaults: d)
        XCTAssertEqual(second.settings, ScrollSettings(reverse: true, speed: 3, smooth: true))
        XCTAssertFalse(tap.isRunning)
        second.restoreOnLaunch()
        XCTAssertTrue(tap.isRunning)
        XCTAssertEqual(second.status, .on)
    }
}
