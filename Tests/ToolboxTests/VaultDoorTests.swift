import XCTest
@testable import Toolbox

final class VaultDoorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-door-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        killProgramsLeftRunning()
        try? FileManager.default.removeItem(at: dir)
    }

    private func folder(_ name: String) -> URL { dir.appendingPathComponent(name) }

    // MARK: One open, one lock

    func testTheDoorGoesFromClosedToOpenAndBackAndSaysSoEachTime() async throws {
        let stand = DoorStandIn()
        try await makeVaultImage(in: folder("plain"))
        let door = makeDoor(in: folder("plain"), tool: stand.tool)
        XCTAssertEqual(door.state, .closed)
        XCTAssertFalse(door.holdsOwnership)

        let wrong = await door.unlock(password: "wrong-pass")
        XCTAssertEqual(wrong, .refused(.wrongPassword))
        XCTAssertEqual(door.state, .closed)
        XCTAssertFalse(door.holdsOwnership, "a failed unlock kept the vault claimed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: door.disk.location.mountPoint.path))

        let opened = await door.unlock(password: Self.vaultPassword)
        XCTAssertEqual(opened, .opened)
        XCTAssertEqual(door.state, .open)
        XCTAssertTrue(door.disk.isOpen)
        XCTAssertTrue(door.holdsOwnership)
        XCTAssertTrue(FileManager.default.fileExists(atPath: door.disk.location.mountPoint.appendingPathComponent(VaultDisk.spotlightOptOut).path))

        let locked = await door.lock()
        XCTAssertEqual(locked, .locked)
        XCTAssertEqual(door.state, .closed)
        XCTAssertFalse(door.disk.isOpen)
        XCTAssertFalse(door.holdsOwnership)
        XCTAssertFalse(FileManager.default.fileExists(atPath: door.disk.location.mountPoint.path))
        XCTAssertEqual(stand.steps.value, ["attach", "attach", "eject"])
        let lockedAgain = await door.lock()
        XCTAssertEqual(lockedAgain, .locked)
        XCTAssertEqual(stand.steps.value.count, 3, "locking a closed vault ran a disk tool")
    }

    func testAnOpenVaultIsNotAWayAroundThePassword() async throws {
        let stand = DoorStandIn()
        let door = try await makeOpenDoor(in: folder("already-open"), tool: stand.tool)

        let wrong = await door.unlock(password: "wrong-pass")

        XCTAssertEqual(wrong, .refused(.wrongPassword), "a wrong password was accepted because the vault was already open")
        XCTAssertFalse(door.disk.isOpen)
        XCTAssertEqual(door.state, .closed)
        XCTAssertFalse(door.holdsOwnership)
        XCTAssertEqual(stand.steps.value, ["attach", "eject", "attach"])

        let opened = await door.unlock(password: Self.vaultPassword)
        XCTAssertEqual(opened, .opened)
        let reopened = await door.unlock(password: Self.vaultPassword)
        XCTAssertEqual(reopened, .opened)
        XCTAssertEqual(door.state, .open)
        XCTAssertTrue(door.disk.isOpen)
        XCTAssertEqual(stand.mostClosingsAtOnce, 1)
    }

    func testEveryToolHasItsTimeLimitAndNothingEndsWithTheApp() async throws {
        let stand = DoorStandIn()
        let door = makeDoor(in: folder("limits"), tool: stand.tool)

        let created = await door.create(password: "first-pass")
        let changed = await door.changePassword(from: "first-pass", to: "second-pass")
        let opened = await door.unlock(password: "second-pass")
        let locked = await door.lock()

        XCTAssertNil(created)
        XCTAssertNil(changed)
        XCTAssertEqual(opened, .opened)
        XCTAssertEqual(locked, .locked)
        XCTAssertEqual(stand.timeouts.value, ["create": .untilFinished, "chpass": .untilFinished, "attach": .seconds(60), "eject": .seconds(6)])
        XCTAssertFalse(stand.timeouts.value.values.contains(.untilCancelled), "quitting stops programs that run until cancelled")
        XCTAssertEqual(VaultDoor.Bounds().lock, 18)
    }

    func testAnEncryptedVaultOpensOnlyWithItsPassword() async throws {
        let door = makeDoor(in: folder("password"))
        let created = await door.create(password: "first-pass")
        XCTAssertNil(created)
        let sameAgain = await door.create(password: "first-pass")
        XCTAssertEqual(sameAgain, .alreadyExists)

        let wrongChange = await door.changePassword(from: "wrong-pass", to: "second-pass")
        XCTAssertEqual(wrongChange, .wrongPassword)
        let changed = await door.changePassword(from: "first-pass", to: "second-pass")
        XCTAssertNil(changed)
        XCTAssertFalse(door.holdsOwnership, "changing the password of a closed vault kept it claimed")

        let old = await door.unlock(password: "first-pass")
        XCTAssertEqual(old, .refused(.wrongPassword))
        let new = await door.unlock(password: "second-pass")
        XCTAssertEqual(new, .opened)
        let whileOpen = await door.changePassword(from: "second-pass", to: "third-pass")
        XCTAssertNil(whileOpen)
        XCTAssertEqual(door.state, .open)
        XCTAssertTrue(door.holdsOwnership)
    }

    // MARK: A lock while the vault is mounting

    func testALockDuringASlowMountStopsTheMountAndNothingIsMounted() async throws {
        let stand = DoorStandIn()
        stand.play("attach", as: .hangs)
        try await makeVaultImage(in: folder("slow-mount"))
        let door = makeDoor(in: folder("slow-mount"), tool: stand.tool)

        let unlocking = Task { await door.unlock(password: Self.vaultPassword) }
        try await waitUntil("the mount is under way") { door.state == .mounting && stand.isHanging("attach") }
        let locked = await door.lock()
        let unlocked = await unlocking.value

        XCTAssertEqual(locked, .locked)
        XCTAssertEqual(unlocked, .lockedMeanwhile)
        XCTAssertEqual(stand.stopped.value, ["attach"])
        XCTAssertEqual(Shell.livePIDs, [], "the mount was still running after the lock had answered")
        XCTAssertEqual(stand.steps.value, ["attach"], "nothing was mounted, so nothing was to be ejected")
        XCTAssertEqual(door.state, .closed)
        XCTAssertFalse(door.disk.isOpen)
        XCTAssertFalse(door.holdsOwnership)
        XCTAssertFalse(FileManager.default.fileExists(atPath: door.disk.location.mountPoint.path))
    }

    func testALockAfterTheMountLandedEjectsItOnceInTheSameSequence() async throws {
        let stand = DoorStandIn()
        stand.play("attach", as: .mountsThenHangs)
        try await makeVaultImage(in: folder("landed"))
        let door = makeDoor(in: folder("landed"), tool: stand.tool)

        let unlocking = Task { await door.unlock(password: Self.vaultPassword) }
        try await waitUntil(timeout: .seconds(60), "the vault is mounted and the mount has not returned") { door.disk.isOpen && stand.isHanging("attach") }
        let locked = await door.lock()
        let unlocked = await unlocking.value

        XCTAssertEqual(locked, .locked)
        XCTAssertEqual(unlocked, .lockedMeanwhile)
        XCTAssertEqual(stand.steps.value, ["attach", "eject"], "the mount that landed was ejected exactly once")
        XCTAssertEqual(Shell.livePIDs, [])
        XCTAssertFalse(door.disk.isOpen, "the lock answered with the vault still mounted")
        XCTAssertEqual(door.state, .closed)
        XCTAssertFalse(door.holdsOwnership)
    }

    func testUnlocksWaitingTheirTurnAreVoidedByALock() async throws {
        let stand = DoorStandIn()
        stand.play("attach", as: .hangs)
        try await makeVaultImage(in: folder("queued"))
        let door = makeDoor(in: folder("queued"), tool: stand.tool)

        let first = Task { await door.unlock(password: Self.vaultPassword) }
        try await waitUntil("the first mount is under way") { stand.isHanging("attach") }
        let second = Task { await door.unlock(password: Self.vaultPassword) }
        try await pause(for: .milliseconds(50), because: "the second unlock has to be waiting its turn when the lock comes")
        stand.play("attach", as: .real)
        let locked = await door.lock()

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(locked, .locked)
        XCTAssertEqual(firstOutcome, .lockedMeanwhile)
        XCTAssertEqual(secondOutcome, .lockedMeanwhile, "an unlock asked for before the lock opened the vault after it")
        XCTAssertFalse(door.disk.isOpen)
        XCTAssertEqual(stand.steps.value, ["attach"])
    }

    func testNoTwoEjectsEverRunAtOnce() async throws {
        let stand = DoorStandIn()
        let door = try await makeOpenDoor(in: folder("one-at-a-time"), tool: stand.tool)

        async let first = door.lock()
        async let second = door.lock()
        let third = door.startLock()
        let relocking = Task { await door.unlock(password: Self.vaultPassword) }
        let outcomes = await [first, second, third.value()]
        _ = await relocking.value
        let last = await door.lock()

        XCTAssertEqual(outcomes, [.locked, .locked, .locked])
        XCTAssertEqual(last, .locked)
        XCTAssertEqual(stand.mostClosingsAtOnce, 1)
        XCTAssertFalse(door.disk.isOpen)
    }

    // MARK: Ejects that fail

    func testAnEjectThatTimesOutStillForcesTheVaultClosed() async throws {
        let stand = DoorStandIn()
        let door = try await makeOpenDoor(in: folder("stuck-eject"), tool: stand.tool, bounds: VaultDoor.Bounds(lockStep: 0.3))
        stand.play("eject", as: .hangs)

        let locked = await door.lock()

        XCTAssertEqual(locked, .locked)
        XCTAssertEqual(stand.steps.value, ["attach", "eject", "detach"])
        XCTAssertEqual(stand.stopped.value, ["eject"])
        XCTAssertFalse(door.disk.isOpen)
    }

    func testAVaultThatWillNotEjectStaysOursAndSaysWhy() async throws {
        let stand = DoorStandIn()
        let door = try await makeOpenDoor(in: folder("busy"), tool: stand.tool)
        stand.play("eject", as: .fails("Volume Vault on disk9 failed to unmount"))
        stand.play("detach", as: .fails("hdiutil: couldn't unmount \"disk9\" - Resource busy"))

        let refused = await door.lock()

        XCTAssertEqual(refused, .stillMounted(reason: "hdiutil: couldn't unmount \"disk9\" - Resource busy"))
        XCTAssertEqual(door.state, .open)
        XCTAssertTrue(door.holdsOwnership, "a vault that is still mounted was given up to other copies")
        XCTAssertTrue(door.disk.isOpen)

        stand.play("eject", as: .real)
        let retried = await door.lock()
        XCTAssertEqual(retried, .locked)
        XCTAssertFalse(door.disk.isOpen)
    }

    // MARK: Mounts that fail

    func testAMountThatTimesOutAfterAttachingIsClosedAgain() async throws {
        let stand = DoorStandIn()
        stand.play("attach", as: .mountsThenHangs)
        try await makeVaultImage(in: folder("half-mounted"))
        let door = makeDoor(in: folder("half-mounted"), tool: stand.tool, bounds: VaultDoor.Bounds(attach: 3))

        let outcome = await door.unlock(password: Self.vaultPassword)

        XCTAssertEqual(outcome, .refused(.diskTool(action: "open", message: "sh did not finish within 3 seconds, so it was stopped.")))
        XCTAssertEqual(stand.steps.value, ["attach", "eject"])
        XCTAssertFalse(door.disk.isOpen)
        XCTAssertEqual(door.state, .closed)
        XCTAssertFalse(door.holdsOwnership)
        XCTAssertFalse(FileManager.default.fileExists(atPath: door.disk.location.mountPoint.path))
    }

    func testAMountThatCannotStartLeavesNoFolderBehind() async throws {
        let stand = DoorStandIn()
        stand.play("attach", as: .cannotStart)
        let door = makeDoor(in: folder("no-start"), tool: stand.tool)

        let outcome = await door.unlock(password: "any-pass")

        XCTAssertEqual(outcome, .refused(.diskTool(action: "open", message: "Could not start diskutil.")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: door.disk.location.mountPoint.path))
        XCTAssertEqual(door.state, .closed)
        XCTAssertFalse(door.holdsOwnership)
    }

    func testUnlockRefusesAMountPointThatAlreadyHoldsFiles() async throws {
        let stand = DoorStandIn()
        try await makeVaultImage(in: folder("stray"))
        let door = makeDoor(in: folder("stray"), tool: stand.tool)
        let mountPoint = door.disk.location.mountPoint
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        let stray = mountPoint.appendingPathComponent("stray.png")
        try Data("left outside".utf8).write(to: stray)
        let shown = (mountPoint.path as NSString).abbreviatingWithTildeInPath

        let refused = await door.unlock(password: Self.vaultPassword)

        XCTAssertEqual(refused, .refused(.filesLeftOutside(count: 1, folder: shown)))
        XCTAssertEqual(VaultError.filesLeftOutside(count: 1, folder: shown).localizedDescription,
                       "1 file was found in the vault's open folder, outside the vault: \(shown). Move it somewhere else, then unlock again.")
        XCTAssertEqual(stand.steps.value, [], "the vault was mounted over an unprotected file")
        XCTAssertFalse(door.holdsOwnership)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))

        try FileManager.default.removeItem(at: stray)
        try Data().write(to: mountPoint.appendingPathComponent(".DS_Store"))
        try Data().write(to: mountPoint.appendingPathComponent(VaultDisk.spotlightOptOut))
        let opened = await door.unlock(password: Self.vaultPassword)
        XCTAssertEqual(opened, .opened)
    }

    func testTheRefusalNamesTheFolderAndSaysWhatToDo() {
        let message = VaultError.filesLeftOutside(count: 3, folder: "~/Vault/Open.noindex").localizedDescription

        XCTAssertTrue(message.contains("3 files were found in the vault's open folder, outside the vault"), message)
        XCTAssertTrue(message.contains("~/Vault/Open.noindex"), message)
        XCTAssertTrue(message.contains("Move them somewhere else, then unlock again."), message)
    }

    // MARK: Closed from outside

    func testAVaultEjectedFromOutsideIsNoticedWithoutRunningATool() async throws {
        let stand = DoorStandIn()
        let door = try await makeOpenDoor(in: folder("outside"), tool: stand.tool)
        XCTAssertFalse(door.noticeOutsideEject(), "a mounted vault was taken for an ejected one")

        await Self.detachWhateverIsLeft(at: door.disk)

        XCTAssertTrue(door.noticeOutsideEject())
        XCTAssertEqual(door.state, .closed)
        XCTAssertFalse(door.holdsOwnership)
        XCTAssertFalse(FileManager.default.fileExists(atPath: door.disk.location.mountPoint.path))
        XCTAssertFalse(door.noticeOutsideEject())
        XCTAssertEqual(stand.steps.value, ["attach"])
    }

    // MARK: Where the vault lives

    func testTheVaultFolderArgumentIsADebugAidOnly() {
        let flagged = ["Toolbox", "--page", "home", "--vault-folder", "/tmp/elsewhere"]
        #if DEBUG
        XCTAssertEqual(VaultLocation.launch(arguments: flagged, isDevelopmentRun: true).folder.path, "/tmp/elsewhere")
        XCTAssertEqual(VaultLocation.launch(arguments: flagged, isDevelopmentRun: false).folder.path, "/tmp/elsewhere")
        #else
        XCTAssertEqual(VaultLocation.launch(arguments: flagged, isDevelopmentRun: true), .development)
        XCTAssertEqual(VaultLocation.launch(arguments: flagged, isDevelopmentRun: false), .standard)
        #endif
    }

    func testADevelopmentRunNeverUsesTheOwnersVault() {
        let plain = ["Toolbox", "--page", "home"]

        XCTAssertEqual(VaultLocation.launch(arguments: plain, isDevelopmentRun: true), .development)
        XCTAssertEqual(VaultLocation.launch(arguments: ["Toolbox", "--vault-folder"], isDevelopmentRun: true), .development)
        XCTAssertEqual(VaultLocation.launch(arguments: plain, isDevelopmentRun: false), .standard)
        XCTAssertEqual(VaultLocation.launch(arguments: plain), .development, "tests are a development run")
        XCTAssertNotEqual(VaultLocation.development.folder, VaultLocation.standard.folder)
    }

    func testADoorThatIsOnlyMadeTouchesNothing() {
        let door = VaultDoor(location: VaultLocation(folder: folder("untouched")))

        XCTAssertEqual(door.state, .closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("untouched").path), "making a door wrote to the disk")
    }
}
