import XCTest
@testable import Toolbox

final class NetworkSpeedTests: XCTestCase {
    /// Trimmed output of a real `networkQuality -c` run.
    private let sample = """
    {"base_rtt": 21.019289016723633, "dl_throughput": 9407682, "ul_throughput": 43927120,
     "responsiveness": 27.022682189941406, "interface_name": "en1", "dl_flows": 6}
    """

    func testParsesRealOutputInMegabits() throws {
        let r = try NetworkQuality.parse(Data(sample.utf8))
        XCTAssertEqual(r.downloadMbps, 9.407682, accuracy: 1e-6)
        XCTAssertEqual(r.uploadMbps, 43.92712, accuracy: 1e-6)
        XCTAssertEqual(r.responsiveness, 27)
        XCTAssertEqual(r.latencyMs ?? 0, 21.02, accuracy: 0.01)
        XCTAssertEqual(r.interface, "en1")
        XCTAssertEqual(r.responsivenessLevel, .low)
    }

    /// Opt-in (TOOLBOX_LIVE_NET=1): runs Apple's real networkQuality, which takes up to a minute and uses bandwidth.
    func testLiveSpeedTest() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOOLBOX_LIVE_NET"] == "1", "set TOOLBOX_LIVE_NET=1 to run a real speed test")
        let r = try await NetworkQuality.run(.together)
        print("LIVE-NET down \(r.downloadMbps) up \(r.uploadMbps) rpm \(r.responsiveness ?? -1) latency \(r.latencyMs ?? -1) iface \(r.interface ?? "-")")
        XCTAssertGreaterThan(r.downloadMbps, 0)
        XCTAssertGreaterThan(r.uploadMbps, 0)
        XCTAssertNotNil(r.latencyMs)
    }

    func testMissingThroughputIsAnError() {
        XCTAssertThrowsError(try NetworkQuality.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try NetworkQuality.parse(Data("nope".utf8)))
    }

    func testResponsivenessBands() {
        func level(_ rpm: Int) -> SpeedResult.Responsiveness? { SpeedResult(downloadMbps: 1, uploadMbps: 1, responsiveness: rpm).responsivenessLevel }
        XCTAssertEqual(level(199), .low)
        XCTAssertEqual(level(200), .medium)
        XCTAssertEqual(level(999), .medium)
        XCTAssertEqual(level(1000), .high)
        XCTAssertNil(SpeedResult(downloadMbps: 1, uploadMbps: 1).responsivenessLevel)
    }

    func testGaugeIsLogarithmicFromOneMegabitToOneGigabit() {
        XCTAssertEqual(SpeedResult.gaugeFraction(0.5), 0)
        XCTAssertEqual(SpeedResult.gaugeFraction(1), 0)
        XCTAssertEqual(SpeedResult.gaugeFraction(10), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(SpeedResult.gaugeFraction(100), 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(SpeedResult.gaugeFraction(1000), 1)
        XCTAssertEqual(SpeedResult.gaugeFraction(5000), 1)
    }

    func testAdviceMatchesTheNumbers() {
        XCTAssertTrue(SpeedResult(downloadMbps: 95.9, uploadMbps: 72, responsiveness: 100).advice.contains("lag under load"))
        XCTAssertTrue(SpeedResult(downloadMbps: 300, uploadMbps: 30, responsiveness: 2000).advice.contains("Plenty fast"))
        XCTAssertTrue(SpeedResult(downloadMbps: 2, uploadMbps: 1).advice.hasPrefix("Slow"))
    }

    func testModeArguments() {
        XCTAssertEqual(NetworkQuality.arguments(for: .together), ["-c"])
        XCTAssertEqual(NetworkQuality.arguments(for: .sequential), ["-c", "-s"])
    }

    func testPortNames() {
        let listing = "Hardware Port: Ethernet\nDevice: en0\n\nHardware Port: Wi-Fi\nDevice: en1\n"
        XCTAssertEqual(NetworkQuality.portName(for: "en1", in: listing), "Wi-Fi")
        XCTAssertEqual(NetworkQuality.portName(for: "en0", in: listing), "Ethernet")
        XCTAssertNil(NetworkQuality.portName(for: "en9", in: listing))
    }

    @MainActor func testModelKeepsAndClearsHistory() async throws {
        let suite = "toolbox.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let m = NetworkSpeedTestModel(defaults: defaults, runTest: { _ in SpeedResult(downloadMbps: 50, uploadMbps: 20, responsiveness: 500, latencyMs: 12) })
        m.start()
        while m.isRunning || m.latest == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(m.history.count, 1)
        XCTAssertEqual(NetworkSpeedTestModel(defaults: defaults).history.count, 1, "history is saved")
        m.clearHistory()
        XCTAssertTrue(NetworkSpeedTestModel(defaults: defaults).history.isEmpty)
    }

    @MainActor func testModelReportsFailure() async throws {
        let defaults = UserDefaults(suiteName: "toolbox.tests.\(UUID().uuidString)")!
        let m = NetworkSpeedTestModel(defaults: defaults, runTest: { _ in throw NetworkQuality.QualityError.failed("offline") })
        m.start()
        while m.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(m.state, .failed("offline"))
        XCTAssertTrue(m.history.isEmpty)
    }
}

final class WifiServiceTests: XCTestCase {
    func testQRPayloadEscapesSpecialCharacters() {
        let bs = String(UnicodeScalar(92))
        let p = WifiService.qrPayload(ssid: "My;Net:1", password: "a,b\"c\(bs)d", security: .wpa, hidden: false)
        XCTAssertEqual(p, "WIFI:T:WPA;S:My\(bs);Net\(bs):1;P:a\(bs),b\(bs)\"c\(bs)\(bs)d;;")
    }

    func testQRPayloadVariants() {
        XCTAssertEqual(WifiService.qrPayload(ssid: "Cafe", password: "ignored", security: .none, hidden: false), "WIFI:T:nopass;S:Cafe;;")
        XCTAssertEqual(WifiService.qrPayload(ssid: "A", password: "b", security: .wep, hidden: true), "WIFI:T:WEP;S:A;P:b;H:true;;")
    }

    func testQRImageIsSquareAndMostlyWhiteAtTheEdges() throws {
        let image = try XCTUnwrap(WifiService.qrImage("WIFI:T:WPA;S:Home;P:secret;;", side: 200))
        XCTAssertEqual(image.size, NSSize(width: 200, height: 200))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let corner = try XCTUnwrap(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(corner.brightnessComponent, 0.95, "quiet zone is white")
        XCTAssertNotNil(WifiService.pngData(image))
    }

    func testParsesNetworkListAndInterface() {
        let out = "Preferred networks on en1:\n\tHome Studio\n\tCafe Wi-Fi\n\t5G Guest\n"
        XCTAssertEqual(WifiService.parseNetworks(out), ["Home Studio", "Cafe Wi-Fi", "5G Guest"])
        XCTAssertEqual(WifiService.parseNetworks("Preferred networks on en1:\n"), [])
        let ports = "Hardware Port: Ethernet\nDevice: en0\nEthernet Address: x\n\nHardware Port: Wi-Fi\nDevice: en1\nEthernet Address: y\n"
        XCTAssertEqual(WifiService.interface(inHardwarePorts: ports), "en1")
        XCTAssertNil(WifiService.interface(inHardwarePorts: "Hardware Port: Ethernet\nDevice: en0\n"))
    }

    func testKeychainExitCodes() {
        XCTAssertEqual(WifiService.interpret(status: 0, output: "hunter2\n", error: ""), .found("hunter2"))
        XCTAssertEqual(WifiService.interpret(status: 44, output: "", error: "not found"), .notFound)
        XCTAssertEqual(WifiService.interpret(status: 51, output: "", error: ""), .cancelled)
        XCTAssertEqual(WifiService.interpret(status: 128, output: "", error: ""), .cancelled)
        XCTAssertEqual(WifiService.interpret(status: 1, output: "", error: " boom \n"), .failed("boom"))
    }

    func testPasswordCommandAsksOnlyForTheNamedNetwork() {
        XCTAssertEqual(WifiService.passwordArguments(for: "Home"), ["find-generic-password", "-D", "AirPort network password", "-a", "Home", "-w"])
    }

    /// Lists this Mac's saved networks (names only; no password is read).
    func testListsSavedNetworksOnThisMac() async throws {
        let networks = try await WifiService.savedNetworks()
        XCTAssertTrue(networks.allSatisfy { !$0.isEmpty })
    }
}

final class EjectTests: XCTestCase {
    private func candidate(path: String = "/Volumes/X", local: Bool = true, browsable: Bool = true, builtIn: Bool = false,
                           ejectable: Bool = false, removable: Bool = false, image: Bool = false) -> Bool {
        VolumeScanner.isEjectCandidate(path: path, isLocal: local, isBrowsable: browsable, isInternal: builtIn,
                                       isEjectable: ejectable, isRemovable: removable, isDiskImage: image)
    }

    func testWhatCountsAsEjectable() {
        XCTAssertTrue(candidate(), "external disk")
        XCTAssertTrue(candidate(builtIn: true, removable: true), "card in the built-in slot")
        XCTAssertTrue(candidate(builtIn: true, image: true), "disk image")
        XCTAssertFalse(candidate(path: "/", builtIn: true))
        XCTAssertFalse(candidate(path: "/System/Volumes/Data"))
        XCTAssertFalse(candidate(local: false), "network share")
        XCTAssertFalse(candidate(browsable: false), "hidden volume such as a Time Machine backup")
        XCTAssertFalse(candidate(builtIn: true), "internal, not removable")
    }

    func testDiskImageMountPoints() throws {
        let plist: [String: Any] = ["images": [["system-entities": [["dev-entry": "/dev/disk4"], ["mount-point": "/Volumes/Installer"]]], ["system-entities": []]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(VolumeScanner.diskImageMountPoints(fromPlist: data), ["/Volumes/Installer"])
        XCTAssertTrue(VolumeScanner.diskImageMountPoints(fromPlist: Data()).isEmpty)
    }

    func testRealVolumesNeverIncludeTheStartupDiskOrShares() {
        for v in VolumeScanner.ejectableVolumes(diskImages: []) {
            XCTAssertNotEqual(v.url.path, "/")
            XCTAssertFalse(v.url.path.hasPrefix("/System"))
        }
    }

    @MainActor func testEjectAllContinuesPastABusyVolume() async throws {
        let a = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/A"), name: "A", kind: .drive, capacity: 1)
        let b = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/B"), name: "B", kind: .card, capacity: 1)
        struct Busy: Error {}
        let m = EjectAllDisksModel(scan: { return [a, b] }, eject: { url in if url.lastPathComponent == "A" { throw Busy() } })
        m.refresh()
        while m.volumes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        m.ejectAll()
        while m.isEjecting || m.status.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        guard case .failed = m.status[a.id] else { return XCTFail("A should be busy") }
        XCTAssertEqual(m.status[b.id], .ejected)
        XCTAssertEqual(m.remaining.map(\.name), ["A"])
    }
}
