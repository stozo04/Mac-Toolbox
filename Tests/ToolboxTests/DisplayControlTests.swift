import XCTest
@testable import Toolbox

final class DDCTests: XCTestCase {
    func testChecksumsMatchPublishedDDCExamples() {
        // "Get brightness" is 6E 51 82 01 10 AC on the wire; "set brightness to 50" ends in 9A.
        XCTAssertEqual(DDC.getRequestPacket(vcp: 0x10), [0x82, 0x01, 0x10, 0xAC])
        XCTAssertEqual(DDC.setPacket(vcp: 0x10, value: 0x32), [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    func testSetPacketSplitsTheValueIntoTwoBytes() {
        let p = DDC.setPacket(vcp: 0x62, value: 0x0123)
        XCTAssertEqual(Array(p[0..<5]), [0x84, 0x03, 0x62, 0x01, 0x23])
        XCTAssertEqual(p[5], DDC.checksum(Array(p[0..<5])))
    }

    func testFeatureCodes() {
        XCTAssertEqual(DDC.Control.brightness.vcp, 0x10)
        XCTAssertEqual(DDC.Control.contrast.vcp, 0x12)
        XCTAssertEqual(DDC.Control.volume.vcp, 0x62)
    }

    func testParsesReplyWithOrWithoutTheLeadingSourceByte() throws {
        let body: [UInt8] = [0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00]
        for reply in [[0x6E] + body + [0x00], body + [0x00, 0x00]] {
            let v = try XCTUnwrap(DDC.parseReply(reply, vcp: 0x10))
            XCTAssertEqual(v.current, 50)
            XCTAssertEqual(v.max, 100)
        }
    }

    func testRejectsBadReplies() {
        let ok: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00]
        XCTAssertNil(DDC.parseReply(ok, vcp: 0x12), "answer for a different control")
        var unsupported = ok; unsupported[3] = 0x01
        XCTAssertNil(DDC.parseReply(unsupported, vcp: 0x10), "monitor says the control is unsupported")
        var zeroMax = ok; zeroMax[7] = 0; zeroMax[8] = 0
        XCTAssertNil(DDC.parseReply(zeroMax, vcp: 0x10))
        XCTAssertNil(DDC.parseReply([0x6E, 0x88], vcp: 0x10))
        XCTAssertNil(DDC.parseReply([UInt8](repeating: 0, count: 12), vcp: 0x10))
    }

    func testPercentConversionsRoundTripAndClamp() {
        XCTAssertEqual(DDC.raw(percent: 50, max: 100), 50)
        XCTAssertEqual(DDC.raw(percent: 75, max: 255), 191)
        XCTAssertEqual(DDC.raw(percent: 150, max: 100), 100)
        XCTAssertEqual(DDC.raw(percent: -5, max: 100), 0)
        XCTAssertEqual(DDC.percent(current: 191, max: 255), 74.9, accuracy: 0.1)
        XCTAssertEqual(DDC.percent(current: 5, max: 0), 0)
    }
}

@MainActor
final class DisplayControlModelTests: XCTestCase {
    func testRestorePreferenceIsRemembered() {
        let suite = "toolbox.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let a = DisplayControlModel(defaults: d)
        XCTAssertFalse(a.restoreOnOpen)
        a.restoreOnOpen = true
        XCTAssertTrue(DisplayControlModel(defaults: d).restoreOnOpen)
    }

    func testEDIDPrefixMatchesTheRegistryFormat() {
        XCTAssertEqual(DisplayControlModel.edidPrefix(vendor: 0x10AC, model: 0xA0B5), "10ACB5A0")
        XCTAssertEqual(DisplayControlModel.edidPrefix(vendor: 0x05E3, model: 0x2779), "05E37927")
    }

    func testMatchesEachMonitorToItsOwnConnection() {
        let uuids: [String?] = ["05E37927-0000-0000-0C1B-0103803C2278", "10ACB5A0-0000-0000-1E19-010380351E78"]
        XCTAssertEqual(DisplayControlModel.busIndex(vendor: 0x10AC, model: 0xA0B5, edidUUIDs: uuids, sameModelCount: 1, externalCount: 2), 1)
        XCTAssertEqual(DisplayControlModel.busIndex(vendor: 0x05E3, model: 0x2779, edidUUIDs: uuids, sameModelCount: 1, externalCount: 2), 0)
    }

    func testNeverGuessesWhenItCannotTell() {
        let uuids: [String?] = ["10ACB5A0-0000-0000-1E19-010380351E78", "10ACB5A0-0000-0000-1E19-010380351E79"]
        XCTAssertNil(DisplayControlModel.busIndex(vendor: 0x10AC, model: 0xA0B5, edidUUIDs: uuids, sameModelCount: 2, externalCount: 2), "two identical monitors")
        XCTAssertNil(DisplayControlModel.busIndex(vendor: 0x1111, model: 0x2222, edidUUIDs: uuids, sameModelCount: 1, externalCount: 2), "no match, two monitors")
        XCTAssertNil(DisplayControlModel.busIndex(vendor: 0x10AC, model: 0xA0B5, edidUUIDs: [], sameModelCount: 1, externalCount: 1))
        XCTAssertEqual(DisplayControlModel.busIndex(vendor: 0x1111, model: 0x2222, edidUUIDs: [nil], sameModelCount: 1, externalCount: 1), 0, "one monitor, one connection")
    }

    /// Read-only: asks each connected external monitor for its current values. Never writes.
    func testLiveReadOnlyProbeOfConnectedMonitors() async throws {
        try XCTSkipUnless(AVServiceBus.isAvailable, "no display connection API on this Mac")
        let monitors = await DisplayControlModel.discover()
        try XCTSkipIf(monitors.isEmpty, "no external monitors connected")
        for m in monitors {
            print("DDC-PROBE", m.name, m.detail, "controllable:", m.isControllable, "maxima:", m.maxima.mapValues { $0 }, "values:", m.values.mapValues { Int($0) }, "problem:", m.problem ?? "-")
            for (control, value) in m.values {
                XCTAssertTrue((0...100).contains(value), "\(m.name) \(control)")
            }
        }
    }

    /// Opt-in (TOOLBOX_DDC_WRITE_TEST=1): writes each control's own current value back and reads it again,
    /// so the write path is exercised without changing anything on the monitor.
    func testLiveWriteOfTheSameValueChangesNothing() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOOLBOX_DDC_WRITE_TEST"] == "1", "set TOOLBOX_DDC_WRITE_TEST=1 to run against real monitors")
        let monitors = await DisplayControlModel.discover().filter(\.isControllable)
        try XCTSkipIf(monitors.isEmpty, "no controllable monitor")
        for m in monitors {
            let bus = try XCTUnwrap(m.bus)
            for (control, max) in m.maxima {
                let before = await bus.read(control)
                let current = try XCTUnwrap(before).current
                let wrote = await bus.write(control, raw: UInt16(current))
                XCTAssertTrue(wrote, "\(m.name) \(control)")
                try await Task.sleep(for: .milliseconds(100))
                let afterRead = await bus.read(control)
                let after = try XCTUnwrap(afterRead)
                XCTAssertEqual(after.current, current, "\(m.name) \(control) must be unchanged")
                XCTAssertEqual(after.max, max)
            }
        }
    }
}
