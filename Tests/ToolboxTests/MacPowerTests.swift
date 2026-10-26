import XCTest
@testable import Toolbox

final class FakeDefaults: DefaultsStore {
    var values: [DefaultsKey: Any] = [:]
    func value(for key: DefaultsKey) -> Any? { values[key] }
    func set(_ value: Any?, for key: DefaultsKey) { values[key] = value }
}

final class FakeRestarter: ProcessRestarter {
    var restarted: [Set<RestartTarget>] = []
    func restart(_ targets: Set<RestartTarget>) { restarted.append(targets) }
}

final class FakePreventer: SleepPreventer {
    private(set) var isHeld = false
    private(set) var display = false
    func hold(keepDisplayOn: Bool, reason: String) { isHeld = true; display = keepDisplayOn }
    func release() { isHeld = false }
}

final class PowerAssertionsLiveTests: XCTestCase {
    private func assertions() async throws -> String {
        try await Shell.run("/usr/bin/pmset", ["-g", "assertions"]).out
    }

    /// The real IOKit assertions appear in `pmset -g assertions` while held and are gone after release.
    func testRealAssertionsAreVisibleToThePowerManager() async throws {
        let reason = "Toolbox Keep Awake \(UUID().uuidString.prefix(8))"
        let held = PowerAssertions()
        held.hold(keepDisplayOn: true, reason: reason)
        let during = try await assertions()
        XCTAssertTrue(during.contains(reason), "assertion should be listed while held")
        XCTAssertTrue(during.contains("PreventUserIdleSystemSleep"))
        XCTAssertTrue(during.contains("PreventUserIdleDisplaySleep"))
        held.release()
        let after = try await assertions()
        XCTAssertFalse(after.contains(reason), "assertion should be gone after release")
        XCTAssertFalse(held.isHeld)
    }

    func testDisplayAssertionIsOptional() async throws {
        let reason = "Toolbox Keep Awake \(UUID().uuidString.prefix(8))"
        let held = PowerAssertions()
        held.hold(keepDisplayOn: false, reason: reason)
        defer { held.release() }
        let lines = try await assertions().split(separator: "\n").filter { $0.contains(reason) }
        XCTAssertEqual(lines.count, 1, "only the system-sleep assertion, so the screen may still turn off")
        XCTAssertTrue(lines[0].contains("PreventUserIdleSystemSleep"))
    }
}

@MainActor
final class KeepAwakeTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var onPower = true

    private func make(_ preventer: FakePreventer) -> KeepAwakeModel {
        KeepAwakeModel(assertions: preventer, now: { self.clock }, onPowerAdapter: { self.onPower })
    }

    func testStartHoldsAndStopReleases() {
        let p = FakePreventer(), m = make(p)
        m.duration = .hour1
        m.start()
        XCTAssertTrue(p.isHeld)
        XCTAssertEqual(m.remaining(at: clock), 3600)
        m.stop()
        XCTAssertFalse(p.isHeld)
        XCTAssertEqual(m.state, .off)
    }

    func testStartingAgainReplacesTheTimer() {
        let p = FakePreventer(), m = make(p)
        m.duration = .hour1
        m.start()
        clock = clock.addingTimeInterval(1800)
        m.duration = .min30
        m.start()
        XCTAssertEqual(m.remaining(at: clock), 1800)
        m.stop()
    }

    func testDisplayToggleAppliesRightAway() {
        let p = FakePreventer(), m = make(p)
        m.start()
        XCTAssertTrue(p.display)
        m.keepDisplayOn = false
        XCTAssertFalse(p.display)
        XCTAssertTrue(p.isHeld)
        m.stop()
    }

    func testOnlyOnPowerAdapterPausesOnBatteryAndResumes() {
        let p = FakePreventer(), m = make(p)
        m.onlyOnPowerAdapter = true
        onPower = false
        m.start()
        XCTAssertFalse(p.isHeld)
        guard case .waitingForPower = m.state else { return XCTFail("\(m.state)") }
        onPower = true
        m.refresh()
        XCTAssertTrue(p.isHeld)
        m.stop()
    }

    func testNoTimerForever() {
        let p = FakePreventer(), m = make(p)
        m.duration = .forever
        m.start()
        XCTAssertNil(m.remaining(at: clock))
        XCTAssertEqual(m.state, .awake(until: nil))
        m.stop()
    }

    func testFormat() {
        XCTAssertEqual(KeepAwakeModel.format(3582), "59:42")
        XCTAssertEqual(KeepAwakeModel.format(3600), "1:00:00")
        XCTAssertEqual(KeepAwakeModel.format(0.2), "0:01")
    }
}

@MainActor
final class HiddenSettingsTests: XCTestCase {
    private func setting(_ id: String) -> HiddenSetting { HiddenSetting.all.first { $0.id == id }! }

    func testIdsAreUniqueAndEveryGroupHasSettings() {
        XCTAssertEqual(Set(HiddenSetting.all.map(\.id)).count, HiddenSetting.all.count)
        for g in HiddenSetting.Group.allCases { XCTAssertFalse(HiddenSetting.settings(in: g).isEmpty) }
    }

    func testToggleReadsDefaultsWritesAndResets() {
        let store = FakeDefaults(), restarter = FakeRestarter()
        let m = HiddenSettingsModel(store: store, restarter: restarter)
        let s = setting("finder.path")
        XCTAssertFalse(m.isOn(s))
        XCTAssertFalse(m.isModified(s))
        m.setOn(true, s)
        XCTAssertEqual(store.values[s.key] as? Bool, true)
        XCTAssertTrue(m.isOn(s))
        XCTAssertTrue(m.isModified(s))
        m.reset(s)
        XCTAssertNil(store.values[s.key])
        XCTAssertFalse(m.isModified(s))
    }

    func testInvertedKeysAreShownTheRightWayRound() {
        let store = FakeDefaults()
        let m = HiddenSettingsModel(store: store, restarter: FakeRestarter())
        let shadow = setting("shots.shadow")
        XCTAssertTrue(m.isOn(shadow), "shadows are on unless disable-shadow is set")
        m.setOn(false, shadow)
        XCTAssertEqual(store.values[shadow.key] as? Bool, true)
        XCTAssertFalse(m.isOn(shadow))
        let plain = setting("textedit.plain")
        XCTAssertFalse(m.isOn(plain))
        m.setOn(true, plain)
        XCTAssertEqual(store.values[plain.key] as? Bool, false)
    }

    func testStoredDefaultValueIsNotShownAsModified() {
        let store = FakeDefaults()
        let m = HiddenSettingsModel(store: store, restarter: FakeRestarter())
        let recents = setting("dock.recents")
        store.values[recents.key] = true
        XCTAssertFalse(m.isModified(recents))
        XCTAssertTrue(m.isOn(recents))
    }

    func testSlidersAndChoices() {
        let store = FakeDefaults()
        let m = HiddenSettingsModel(store: store, restarter: FakeRestarter())
        let delay = setting("dock.delay")
        XCTAssertNil(m.number(delay))
        m.setNumber(0.123, delay)
        XCTAssertEqual(m.number(delay), 0.12)
        let format = setting("shots.format")
        XCTAssertEqual(m.text(format), "png")
        m.setText("jpg", format)
        XCTAssertTrue(m.isModified(format))
        m.resetAll()
        XCTAssertNil(m.number(delay))
        XCTAssertEqual(m.text(format), "png")
        XCTAssertFalse(m.anyModified)
    }

    func testChangesRestartTheRightProcessOnce() async throws {
        let restarter = FakeRestarter()
        let m = HiddenSettingsModel(store: FakeDefaults(), restarter: restarter)
        let delay = setting("dock.delay")
        for v in [0.1, 0.2, 0.3] { m.setNumber(v, delay) }
        m.setOn(true, setting("finder.path"))
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(restarter.restarted.count, 1)
        XCTAssertEqual(restarter.restarted.first, [.dock, .finder])
    }

    func testSystemDefaultsRoundTripInAScratchDomain() {
        let key = DefaultsKey(domain: "com.toolbox.tests.\(UUID().uuidString)", name: "x")
        let d = SystemDefaults.shared
        XCTAssertNil(d.value(for: key))
        d.set(true, for: key)
        XCTAssertEqual((d.value(for: key) as? NSNumber)?.boolValue, true)
        d.set(nil, for: key)
        XCTAssertNil(d.value(for: key))
    }
}

@MainActor
final class PresentationModeTests: XCTestCase {
    private func make(_ store: FakeDefaults, _ restarter: FakeRestarter, _ awake: FakePreventer, _ suite: UserDefaults) -> PresentationModeModel {
        PresentationModeModel(store: store, restarter: restarter, awake: awake, saved: suite)
    }

    private func suite() -> UserDefaults {
        let name = "toolbox.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testOnChangesSettingsAndOffRestoresPreviousValues() {
        let store = FakeDefaults(), r = FakeRestarter(), awake = FakePreventer(), d = suite()
        store.values[PresentationModeModel.dockAutohide] = false   // desktop icons key was never set
        let m = make(store, r, awake, d)
        m.turnOn()
        XCTAssertTrue(m.isOn)
        XCTAssertEqual(store.values[PresentationModeModel.desktopIcons] as? Bool, false)
        XCTAssertEqual(store.values[PresentationModeModel.dockAutohide] as? Bool, true)
        XCTAssertTrue(awake.isHeld)
        XCTAssertEqual(r.restarted.last, [.finder, .dock])
        m.turnOff()
        XCTAssertNil(store.values[PresentationModeModel.desktopIcons], "an unset key goes back to unset")
        XCTAssertEqual(store.values[PresentationModeModel.dockAutohide] as? Bool, false)
        XCTAssertFalse(awake.isHeld)
        XCTAssertFalse(m.isOn)
    }

    func testStateSurvivesRelaunch() {
        let store = FakeDefaults(), d = suite()
        store.values[PresentationModeModel.dockAutohide] = true
        let first = make(store, FakeRestarter(), FakePreventer(), d)
        first.turnOn()
        let awake = FakePreventer()
        let second = make(store, FakeRestarter(), awake, d)
        XCTAssertTrue(second.isOn)
        XCTAssertTrue(awake.isHeld)
        second.turnOff()
        XCTAssertEqual(store.values[PresentationModeModel.dockAutohide] as? Bool, true, "the Dock was already hidden before")
    }
}
