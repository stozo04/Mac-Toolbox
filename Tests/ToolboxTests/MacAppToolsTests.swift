import XCTest
@testable import Toolbox

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A minimal fake app bundle: Name.app/Contents/Info.plist (+ a binary-ish file).
@discardableResult
private func makeApp(in dir: URL, name: String, bundleID: String) throws -> URL {
    let app = dir.appendingPathComponent("\(name).app")
    let contents = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleShortVersionString": "1.2"]
    try (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data(repeating: 1, count: 10_000).write(to: contents.appendingPathComponent(name))
    return app
}

final class CodeSignInfoTests: XCTestCase {
    func testDeveloperNames() {
        XCTAssertEqual(CodeSignInfo.developerName(fromCertificateSummary: "Developer ID Application: Google LLC (EQHXZ8M8AV)"), "Google LLC")
        XCTAssertEqual(CodeSignInfo.developerName(fromCertificateSummary: "Apple Development: Jane Doe (ABCDE12345)"), "Jane Doe")
        XCTAssertEqual(CodeSignInfo.developerName(fromCertificateSummary: "Mac Developer: Jane Doe (ABCDE12345)"), "Jane Doe")
        XCTAssertEqual(CodeSignInfo.developerName(fromCertificateSummary: "Software Signing"), "Apple")
        XCTAssertEqual(CodeSignInfo.developerName(fromCertificateSummary: "macOS Software Signing"), "Apple")
        XCTAssertEqual(CodeSignInfo.developerName(fromCertificateSummary: "Apple Mac OS Application Signing"), "Apple")
        XCTAssertEqual(CodeSignInfo.developerName(fromCertificateSummary: "Some Company"), "Some Company")
    }

    func testAppleAppIsSignedValidAndFromApple() {
        let info = CodeSignInfo.inspect(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        XCTAssertTrue(info.isSigned)
        XCTAssertTrue(info.isValid)
        XCTAssertTrue(info.isApple)
    }

    func testPlainFileIsUnsigned() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tool")
        try Data("hi".utf8).write(to: file)
        XCTAssertEqual(CodeSignInfo.inspect(file), .unsigned)
        XCTAssertEqual(CodeSignInfo.inspect(dir.appendingPathComponent("missing")), .unsigned)
    }
}

final class FixDamagedAppTests: XCTestCase {
    func testParsesSpctlOutput() {
        XCTAssertEqual(AppInspector.parseAssessment(status: 0, output: "/A.app: accepted\nsource=Notarized Developer ID\n"), .notarized)
        XCTAssertEqual(AppInspector.parseAssessment(status: 0, output: "accepted\nsource=Developer ID\n"), .developerID)
        XCTAssertEqual(AppInspector.parseAssessment(status: 0, output: "accepted\nsource=Mac App Store\n"), .appStore)
        guard case .rejected(let unsigned) = AppInspector.parseAssessment(status: 3, output: "rejected\nsource=no usable signature") else { return XCTFail() }
        XCTAssertTrue(unsigned.contains("not signed"))
        guard case .rejected(let changed) = AppInspector.parseAssessment(status: 3, output: "a sealed resource is missing or invalid\nrejected") else { return XCTFail() }
        XCTAssertTrue(changed.contains("changed"))
        XCTAssertEqual(AppInspector.parseAssessment(status: 1, output: ""), .unknown)
    }

    func testQuarantineIsFoundAndClearedEverywhereInsideTheApp() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(in: dir, name: "Thing", bundleID: "com.test.thing")
        let inner = app.appendingPathComponent("Contents/MacOS/Thing")
        for url in [app, inner] {
            XCTAssertEqual(setxattr(url.path, Quarantine.attribute, "0081;00000000;Safari;", 21, 0, 0), 0)
        }
        XCTAssertTrue(Quarantine.isQuarantined(app))
        XCTAssertEqual(try Quarantine.clear(at: app), 2)
        XCTAssertFalse(Quarantine.isQuarantined(app))
        XCTAssertFalse(Quarantine.isQuarantined(inner))
        XCTAssertEqual(try Quarantine.clear(at: app), 0, "clearing again is harmless")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inner.path), "the app itself is untouched")
    }

    func testRefusesNonAppsAndSystemApps() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try await AppInspector.inspect(dir.appendingPathComponent("notes.txt")); XCTFail() } catch AppInspector.InspectError.notAnApp {}
        do { _ = try await AppInspector.inspect(URL(fileURLWithPath: "/System/Applications/Calculator.app")); XCTFail() } catch AppInspector.InspectError.systemApp {}
    }

    func testInspectsAFakeAppAsQuarantinedAndUnsigned() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(in: dir, name: "Thing", bundleID: "com.test.thing")
        setxattr(app.path, Quarantine.attribute, "0081;00000000;Safari;", 21, 0, 0)
        let d = try await AppInspector.inspect(app)
        XCTAssertEqual(d.name, "Thing")
        XCTAssertEqual(d.bundleID, "com.test.thing")
        XCTAssertEqual(d.version, "1.2")
        XCTAssertTrue(d.isQuarantined)
        XCTAssertFalse(d.signature.isSigned)
    }

    @MainActor func testVerdicts() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(in: dir, name: "Thing", bundleID: "com.test.thing")
        setxattr(app.path, Quarantine.attribute, "0081;00000000;Safari;", 21, 0, 0)
        let m = FixDamagedAppModel()
        m.load(app)
        while m.app == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(m.verdict?.text.contains("blocks") ?? false)
        m.clearQuarantine()
        XCTAssertEqual(m.outcome, .cleared)
        XCTAssertFalse(Quarantine.isQuarantined(app))
    }
}

final class ResetPermissionsTests: XCTestCase {
    func testArguments() {
        XCTAssertEqual(PermissionResetter.arguments(service: "Microphone", bundleID: "com.foo.Bar-App"), ["reset", "Microphone", "com.foo.Bar-App"])
        XCTAssertEqual(PermissionResetter.arguments(service: "All", bundleID: "com.foo.bar"), ["reset", "All", "com.foo.bar"])
    }

    func testRefusesBadInput() {
        XCTAssertNil(PermissionResetter.arguments(service: "Microphone", bundleID: ""), "never reset for every app")
        XCTAssertNil(PermissionResetter.arguments(service: "Microphone", bundleID: "-a"))
        XCTAssertNil(PermissionResetter.arguments(service: "Microphone", bundleID: "com.foo; rm -rf ~"))
        XCTAssertNil(PermissionResetter.arguments(service: "Microphone", bundleID: "com.foo bar"))
        XCTAssertNil(PermissionResetter.arguments(service: "NotAService", bundleID: "com.foo.bar"))
    }

    func testServiceListIsUniqueAndHasTheBigThree() {
        XCTAssertEqual(Set(PrivacyService.all.map(\.id)).count, PrivacyService.all.count)
        for id in ["ScreenCapture", "Microphone", "Camera"] { XCTAssertTrue(PrivacyService.all.contains { $0.id == id }) }
    }

    func testRealCommandSucceedsForAnAppThatHasNoPermissionToReset() async throws {
        // Calculator never asks for the camera, so this changes nothing but exercises the real tccutil.
        try await PermissionResetter.reset(service: "Camera", bundleID: "com.apple.calculator")
    }

    func testUnknownAppGivesAFriendlyMessage() async {
        do {
            try await PermissionResetter.reset(service: "Camera", bundleID: "com.toolbox.tests.nonexistent")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("doesn't know this app"), error.localizedDescription)
        }
    }

    @MainActor func testModelReportsEachResult() async throws {
        let m = ResetPermissionsModel(reset: { service, _ in if service == "Camera" { throw PermissionResetter.ResetError.failed("nope") } })
        m.selected = InstalledApp(url: URL(fileURLWithPath: "/Applications/X.app"), name: "X", bundleID: "com.x.y")
        m.reset(PrivacyService.all.first { $0.id == "Microphone" }!)
        m.reset(PrivacyService.all.first { $0.id == "Camera" }!)
        while m.results.count < 2 || m.results.values.contains(.working) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.results["Microphone"], .done)
        XCTAssertEqual(m.results["Camera"], .failed("nope"))
        m.selected = nil
        XCTAssertTrue(m.results.isEmpty, "results belong to one app")
    }
}

final class UninstallAppTests: XCTestCase {
    func testMatching() {
        let id = "com.acme.Widget"
        func c(_ entry: String, _ place: String = "Preferences") -> Leftover.Confidence? {
            LeftoverScanner.confidence(of: entry, place: place, bundleID: id, appName: "Widget")
        }
        XCTAssertEqual(c("com.acme.Widget.plist"), .exact)
        XCTAssertEqual(c("com.acme.Widget", "Containers"), .exact)
        XCTAssertEqual(c("com.acme.widget.savedState", "Saved Application State"), .exact)
        XCTAssertEqual(c("ABCDE12345.com.acme.Widget", "Group Containers"), .exact)
        XCTAssertEqual(c("com.acme.Widget.helper.plist"), .related)
        XCTAssertEqual(c("Widget", "Application Support"), .nameOnly)
        XCTAssertNil(c("Widget", "Preferences"), "a bare name only counts in the folders apps name after themselves")
        XCTAssertNil(c("com.acme.WidgetPro.plist"), "a longer name is a different app")
        XCTAssertNil(c("com.other.Widget.plist"))
    }

    func testScanFindsOnlyThisAppsFilesAndSizesThem() throws {
        let root = try makeTempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let lib = root.appendingPathComponent("Library")
        let fm = FileManager.default
        for dir in ["Caches/com.acme.Widget", "Application Support/Widget", "Application Support/Other", "Preferences", "Containers/com.acme.Widget/Data"] {
            try fm.createDirectory(at: lib.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 50_000).write(to: lib.appendingPathComponent("Caches/com.acme.Widget/blob"))
        try Data("x".utf8).write(to: lib.appendingPathComponent("Preferences/com.acme.Widget.plist"))
        try Data("x".utf8).write(to: lib.appendingPathComponent("Preferences/com.acme.Other.plist"))
        let app = try makeApp(in: root, name: "Widget", bundleID: "com.acme.Widget")

        let found = LeftoverScanner.scan(app: app, bundleID: "com.acme.Widget", appName: "Widget", library: lib)
        let names = Set(found.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, ["Widget.app", "com.acme.Widget", "Widget", "com.acme.Widget.plist"])
        XCTAssertGreaterThanOrEqual(found.first { $0.url.lastPathComponent == "com.acme.Widget" && $0.place == "Caches" }!.bytes, 50_000)
        XCTAssertTrue(found.first!.isApp)
    }

    func testProtectedApps() {
        XCTAssertTrue(LeftoverScanner.isProtected(bundleID: "com.apple.Safari", appURL: URL(fileURLWithPath: "/Applications/Safari.app")))
        XCTAssertTrue(LeftoverScanner.isProtected(bundleID: "x.y", appURL: URL(fileURLWithPath: "/System/Applications/X.app")))
        XCTAssertFalse(LeftoverScanner.isProtected(bundleID: "com.acme.Widget", appURL: URL(fileURLWithPath: "/Applications/Widget.app")))
    }

    @MainActor func testRemovingMovesOnlyTickedItemsToTheTrash() async throws {
        let root = try makeTempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let lib = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("Caches/com.acme.Widget"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("Application Support/Widget"), withIntermediateDirectories: true)
        let app = try makeApp(in: root, name: "Widget", bundleID: "com.acme.Widget")
        var trashed: [String] = []
        let m = UninstallAppModel(library: lib, trash: { trashed.append($0.lastPathComponent) }, isRunning: { _ in false })
        m.load(app)
        while m.phase != .ready { try await Task.sleep(for: .milliseconds(20)) }
        let nameOnly = try XCTUnwrap(m.items.first { $0.confidence == .nameOnly })
        XCTAssertFalse(m.selection.contains(nameOnly.url), "look-alikes start unticked")
        XCTAssertEqual(m.selection.count, 2, "the app and its exact cache folder")
        m.remove()
        XCTAssertEqual(Set(trashed), ["Widget.app", "com.acme.Widget"])
        guard case .done(let moved, _, let failures) = m.phase else { return XCTFail() }
        XCTAssertEqual(moved, 2)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.appendingPathComponent("Application Support/Widget").path), "unticked item stays")
    }

    @MainActor func testRefusesWhileRunningAndRefusesApple() async throws {
        let root = try makeTempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(in: root, name: "Widget", bundleID: "com.acme.Widget")
        let m = UninstallAppModel(library: root.appendingPathComponent("Library"), trash: { _ in XCTFail("must not trash") }, isRunning: { _ in true })
        m.load(app)
        while m.phase != .ready { try await Task.sleep(for: .milliseconds(20)) }
        m.remove()
        XCTAssertTrue(m.message?.contains("Quit") ?? false)
        XCTAssertEqual(m.phase, .ready)

        let apple = try makeApp(in: root, name: "Fake", bundleID: "com.apple.fake")
        let m2 = UninstallAppModel(library: root, trash: { _ in XCTFail() }, isRunning: { _ in false })
        m2.load(apple)
        XCTAssertNil(m2.app)
        XCTAssertNotNil(m2.message)
    }
}

final class LoginItemsTests: XCTestCase {
    private func writePlist(_ dict: [String: Any], at url: URL) throws {
        try (dict as NSDictionary).write(to: url)
    }

    func testParsesPlists() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.plist")
        try writePlist(["Label": "com.acme.updater", "ProgramArguments": ["/Applications/Acme.app/Contents/MacOS/up", "--x"], "RunAtLoad": true], at: a)
        XCTAssertEqual(LaunchItems.parse(plistAt: a), .init(label: "com.acme.updater", program: "/Applications/Acme.app/Contents/MacOS/up", runAtLoad: true, disabledInPlist: false))
        let b = dir.appendingPathComponent("b.plist")
        try writePlist(["Program": "/usr/bin/true", "Disabled": true], at: b)
        XCTAssertEqual(LaunchItems.parse(plistAt: b), .init(label: "b", program: "/usr/bin/true", runAtLoad: false, disabledInPlist: true))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("c.plist"))
        XCTAssertNil(LaunchItems.parse(plistAt: dir.appendingPathComponent("c.plist")))
    }

    func testParsesDisabledOverrides() {
        let output = """
        disabled services = {
        \t"com.acme.off" => disabled
        \t"com.acme.on" => enabled
        \t"com.acme.old" => true
        }
        """
        XCTAssertEqual(LaunchItems.parseDisabledOverrides(output), ["com.acme.off": true, "com.acme.on": false, "com.acme.old": true])
    }

    func testSigningTargetPrefersTheContainingApp() {
        XCTAssertEqual(LaunchItems.signingTarget(forProgram: "/Applications/Acme.app/Contents/Library/up"), "/Applications/Acme.app")
        XCTAssertEqual(LaunchItems.signingTarget(forProgram: "/usr/local/bin/tool"), "/usr/local/bin/tool")
    }

    func testCommands() {
        XCTAssertEqual(LaunchItems.disableCommands(label: "com.a.b", uid: 501), [["disable", "gui/501/com.a.b"], ["bootout", "gui/501/com.a.b"]])
        XCTAssertEqual(LaunchItems.enableCommands(label: "com.a.b", plist: URL(fileURLWithPath: "/x/y.plist"), uid: 501),
                       [["enable", "gui/501/com.a.b"], ["bootstrap", "gui/501", "/x/y.plist"]])
    }

    func testScanReadsFoldersAndAppliesOverrides() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writePlist(["Label": "com.acme.one", "ProgramArguments": ["/usr/bin/true"], "RunAtLoad": true], at: dir.appendingPathComponent("one.plist"))
        try writePlist(["Label": "com.acme.two", "ProgramArguments": ["/does/not/exist"]], at: dir.appendingPathComponent("two.plist"))
        let items = LaunchItems.scan(directories: [(dir, .user)], overrides: ["com.acme.one": true])
        XCTAssertEqual(items.map(\.label), ["one", "two"].map { "com.acme.\($0)" })
        XCTAssertFalse(items[0].isEnabled, "launchctl says it is disabled")
        XCTAssertTrue(items[0].exists)
        XCTAssertTrue(items[0].signature.isSigned, "/usr/bin/true is signed by Apple")
        XCTAssertFalse(items[1].exists)
        XCTAssertEqual(items[1].developerText, "Program is missing")
        XCTAssertTrue(items[0].scope.canToggle)
    }

    func testNamesComeFromTheAppAndSignaturesAreDescribedPlainly() {
        func item(program: String?, exists: Bool = true, signature: CodeSignInfo = .unsigned) -> LaunchItem {
            LaunchItem(label: "com.acme.thing.agent", plist: URL(fileURLWithPath: "/u/x.plist"), scope: .user, program: program,
                       runsAtLogin: true, isEnabled: true, signature: signature, exists: exists)
        }
        XCTAssertEqual(item(program: "/Applications/Acme Sync.app/Contents/Library/helper").displayName, "Acme Sync")
        XCTAssertEqual(item(program: "/usr/local/bin/tool").displayName, "com.acme.thing.agent")
        XCTAssertEqual(item(program: nil).displayName, "com.acme.thing.agent")
        XCTAssertEqual(item(program: "/x", exists: false).developerText, "Program is missing")
        XCTAssertEqual(item(program: "/x").developerText, "Unknown (not signed)")
        XCTAssertEqual(item(program: "/x", signature: CodeSignInfo(isSigned: true, isValid: true, isAdHoc: true)).developerText, "Signed on this Mac, not by a developer")
        XCTAssertEqual(item(program: "/x", signature: CodeSignInfo(isSigned: true, isValid: true, developer: "Acme Inc.")).developerText, "Acme Inc.")
    }

    func testSystemItemsCannotBeToggled() async throws {
        let item = LaunchItem(label: "x", plist: URL(fileURLWithPath: "/Library/LaunchDaemons/x.plist"), scope: .system, program: nil,
                              runsAtLogin: true, isEnabled: true, signature: .unsigned, exists: false)
        do { try await LaunchItems.setEnabled(false, item: item); XCTFail() } catch LaunchItems.ToggleError.needsAdmin {}
    }

    func testRealScanOfThisMacRuns() async {
        let overrides = await LaunchItems.currentOverrides()
        let items = LaunchItems.scan(overrides: overrides)
        XCTAssertTrue(items.allSatisfy { !$0.label.isEmpty })
    }

    @MainActor func testModelToggleUpdatesAndReportsErrors() async throws {
        let ok = LaunchItem(label: "com.a.ok", plist: URL(fileURLWithPath: "/u/ok.plist"), scope: .user, program: nil, runsAtLogin: true, isEnabled: true, signature: .unsigned, exists: false)
        let bad = LaunchItem(label: "com.a.bad", plist: URL(fileURLWithPath: "/u/bad.plist"), scope: .user, program: nil, runsAtLogin: true, isEnabled: true, signature: .unsigned, exists: false)
        let m = LoginItemsModel(scan: { [ok, bad] }, setEnabled: { _, item in if item.label == "com.a.bad" { throw LaunchItems.ToggleError.failed("denied") } })
        m.refresh()
        while m.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        m.toggle(ok, to: false)
        m.toggle(bad, to: false)
        while m.errors.isEmpty || m.items.first(where: { $0.label == "com.a.ok" })?.isEnabled == true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.errors[bad.id], "denied")
        XCTAssertTrue(m.items.first { $0.label == "com.a.bad" }!.isEnabled, "a failed change leaves the switch on")
    }
}
