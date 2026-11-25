import XCTest
@testable import Toolbox

/// The model on top of the door: what the owner sees when the vault locks, the Mac sleeps or the app quits.
@MainActor
final class VaultLockingTests: XCTestCase {
    private static let shortBounds = VaultDoor.Bounds(attach: 60, lockStep: 0.3, stopGrace: 0.1)
    private var dir: URL!

    override func setUp() async throws {
        dir = try makeVaultTestFolder("locking")
    }

    // MARK: Locking

    func testLockingShowsTheDoorAtOnceAndEjectsInTheBackground() async throws {
        let stand = DoorStandIn()
        let model = try await makeOpenVault("at-once", stand: stand)
        try Data("kept".utf8).write(to: model.root.appendingPathComponent("note.txt"))

        let locking = model.lockImmediately()

        XCTAssertEqual(model.phase, .locked, "the library stayed on screen while the disk ejected")
        XCTAssertTrue(model.isLocking)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.thumbnails)
        XCTAssertTrue(model.disk.isOpen, "the eject ran on the main thread before lockImmediately returned")
        await model.unlock(password: Self.vaultPassword)
        XCTAssertEqual(model.phase, .locked, "the door opened while the vault was still locking")
        await locking.value
        XCTAssertFalse(model.isLocking)
        XCTAssertFalse(model.disk.isOpen)
        XCTAssertEqual(model.door.state, .closed)
        XCTAssertEqual(stand.steps.value.filter { $0 == "eject" }.count, 1)

        await model.unlock(password: Self.vaultPassword)
        XCTAssertEqual(model.phase, .opening)
        XCTAssertEqual(model.door.state, .open)
    }

    func testTheModelFollowsTheDoorThroughEveryState() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("mirror"))
        let stand = DoorStandIn()
        let model = VaultModel(location: location, watchesSystem: false, tool: stand.tool, anotherCopyIsRunning: { false })
        addTeardownBlock { @MainActor in await model.lock() }
        XCTAssertEqual(model.phase, .setup)
        XCTAssertEqual(model.door.state, .closed)

        await model.create(password: Self.vaultPassword, confirmation: Self.vaultPassword)
        XCTAssertEqual(model.phase, .opening)
        XCTAssertEqual(model.door.state, .open)
        model.finishOpening()
        XCTAssertEqual(model.phase, .open)

        await model.lock()
        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(model.door.state, .closed)

        await model.unlock(password: "wrong-pass")
        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(model.door.state, .closed)
        XCTAssertEqual(model.wrongPasswordAttempts, 1)

        stand.play("attach", as: .cannotStart)
        await model.unlock(password: Self.vaultPassword)
        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(model.message, "The vault couldn't open. Could not start diskutil.")
        XCTAssertEqual(model.door.state, .closed)
    }

    func testTheDoorOffersTheFolderOnlyWhileFilesAreLeftInIt() async throws {
        let model = try await makeLockedVault("stray", stand: DoorStandIn())
        let mountPoint = model.disk.location.mountPoint
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        let stray = mountPoint.appendingPathComponent("stray.png")
        try Data("left outside".utf8).write(to: stray)

        await model.unlock(password: Self.vaultPassword)

        XCTAssertEqual(model.folderWithFilesLeftOutside?.path, mountPoint.path)
        XCTAssertEqual(model.message?.contains("Move it somewhere else, then unlock again."), true, model.message ?? "no message")
        XCTAssertFalse(model.disk.isOpen)

        try FileManager.default.removeItem(at: stray)
        await model.unlock(password: Self.vaultPassword)

        XCTAssertNil(model.folderWithFilesLeftOutside)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.disk.isOpen)
        XCTAssertEqual(model.phase, .opening)
    }

    func testAVaultThatWillNotEjectComesBackOpenWithTheReason() async throws {
        let stand = DoorStandIn()
        let model = try await makeOpenVault("busy", stand: stand)
        stand.play("eject", as: .fails("busy"))
        stand.play("detach", as: .fails("hdiutil: couldn't unmount \"disk9\" - Resource busy"))

        await model.lock()

        XCTAssertEqual(model.phase, .open)
        XCTAssertEqual(model.door.state, .open)
        XCTAssertEqual(model.message, VaultNotices.stillOpen)
        XCTAssertFalse(model.isLocking)

        stand.play("eject", as: .real)
        stand.play("detach", as: .real)
        await model.lock()
        XCTAssertEqual(model.phase, .locked)
        XCTAssertFalse(model.disk.isOpen)
    }

    func testAnotherCopysVaultIsShownAsLockedAndNeverTouched() async throws {
        let theirs = try await makeOpenDoor(in: dir.appendingPathComponent("theirs"))
        let stand = DoorStandIn()
        let model = VaultModel(location: theirs.disk.location, watchesSystem: false, tool: stand.tool, anotherCopyIsRunning: { true })
        try await waitUntil("the launch check has settled") { !model.isLocking }

        await model.unlock(password: Self.vaultPassword)
        XCTAssertEqual(model.message, "The vault is open in another copy of Toolbox. Lock it there first.")
        await model.lock()
        model.lockBeforeSleep()
        try await waitUntil("the sleep lock has settled") { !model.isLocking }
        XCTAssertNil(model.quitGuard.lockBeforeQuitting(), "quitting this copy has nothing to lock")

        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(stand.steps.value, [], "this copy ran a disk tool on a vault another copy is using")
        XCTAssertTrue(theirs.disk.isOpen)
        XCTAssertEqual(theirs.state, .open)
    }

    func testAVaultLeftMountedByACrashIsLockedAtLaunchWhenNoCopyHoldsIt() async throws {
        try await makeVaultImage(in: dir.appendingPathComponent("crashed"))
        var crashed: VaultDoor? = VaultDoor(location: VaultLocation(folder: dir.appendingPathComponent("crashed")), anotherCopyIsRunning: { false })
        let opened = await crashed?.unlock(password: Self.vaultPassword)
        XCTAssertEqual(opened, .opened)
        let disk = try XCTUnwrap(crashed?.disk)
        addTeardownBlock { await Self.detachWhateverIsLeft(at: disk) }
        crashed = nil

        let model = VaultModel(location: disk.location, watchesSystem: false, anotherCopyIsRunning: { false })
        XCTAssertTrue(model.isLocking, "the door could be used before the leftover was dealt with")
        await model.unlock(password: Self.vaultPassword)
        XCTAssertEqual(model.phase, .locked)
        try await waitUntil(timeout: .seconds(60), "the leftover has been locked") { !model.isLocking }

        XCTAssertFalse(disk.isOpen)
        XCTAssertEqual(model.door.state, .closed)
        await model.unlock(password: Self.vaultPassword)
        XCTAssertEqual(model.phase, .opening)
        await model.lock()
    }

    func testALeftoverThatWillNotEjectIsKeptAsThisCopysAndSaysSo() async throws {
        try await makeVaultImage(in: dir.appendingPathComponent("stuck-leftover"))
        var crashed: VaultDoor? = VaultDoor(location: VaultLocation(folder: dir.appendingPathComponent("stuck-leftover")), anotherCopyIsRunning: { false })
        let opened = await crashed?.unlock(password: Self.vaultPassword)
        XCTAssertEqual(opened, .opened)
        let location = try XCTUnwrap(crashed?.disk.location)
        crashed = nil
        let stand = DoorStandIn()
        stand.play("eject", as: .fails("busy"))
        stand.play("detach", as: .fails("hdiutil: couldn't unmount \"disk9\" - Resource busy"))

        let model = VaultModel(location: location, watchesSystem: false, tool: stand.tool, anotherCopyIsRunning: { false })
        addTeardownBlock { @MainActor in
            for verb in DoorStandIn.verbs { stand.play(verb, as: .real) }
            await model.lock()
        }
        try await waitUntil(timeout: .seconds(60), "the launch check has settled") { !model.isLocking }

        XCTAssertTrue(model.disk.isOpen)
        XCTAssertEqual(model.door.state, .open)
        XCTAssertTrue(model.door.holdsOwnership)
        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(model.message, VaultNotices.leftoverStillMounted)
        XCTAssertFalse(model.quitGuard.mayQuit(), "the app could quit without a word with the leftover still mounted")

        stand.play("eject", as: .real)
        await model.unlock(password: Self.vaultPassword)
        XCTAssertEqual(model.phase, .opening)
        XCTAssertEqual(stand.steps.value, ["eject", "detach", "eject", "attach"])
    }

    // MARK: Sleep

    func testSleepDoesNotReturnUntilTheVaultIsLocked() async throws {
        let model = try await makeOpenVault("sleep", stand: DoorStandIn())

        model.lockBeforeSleep()

        XCTAssertFalse(model.disk.isOpen, "the Mac was free to sleep with the vault mounted")
        XCTAssertEqual(model.door.state, .closed)
        XCTAssertEqual(model.phase, .locked)
        try await waitUntil("the lock has settled") { !model.isLocking }
        XCTAssertEqual(model.phase, .locked)
    }

    func testSleepAndTheScreenLockSayTheyAskedForTheLockOnlyWhenTheVaultIsOpen() async throws {
        let sink = MemorySink(minimumLevel: .info)
        Log.configure(sinks: [sink])
        defer { Log.configure(sinks: []) }
        let asked = { sink.events.map(\.message).filter { $0.hasPrefix("Vault locking") } }
        let model = try await makeOpenVault("lock-triggers", stand: DoorStandIn())

        model.lockBeforeSleep()
        try await waitUntil("the lock has settled") { !model.isLocking }
        XCTAssertEqual(asked(), ["Vault locking before sleep"])

        model.lockBeforeSleep()
        model.lockBecauseTheScreenLocked()
        try await waitUntil("the lock has settled") { !model.isLocking }
        XCTAssertEqual(asked(), ["Vault locking before sleep"], "a lock of a closed vault was recorded")

        await model.unlock(password: Self.vaultPassword)
        model.finishOpening()
        XCTAssertEqual(model.phase, .open, model.message ?? "")
        model.lockBecauseTheScreenLocked()
        try await waitUntil("the lock has settled") { !model.isLocking }
        XCTAssertEqual(asked(), ["Vault locking before sleep", "Vault locking because the screen locked"])
    }

    func testSleepDuringAnUnlockStopsTheMountAndEjectsWhatLandedBeforeItReturns() async throws {
        let stand = DoorStandIn()
        stand.play("attach", as: .mountsThenHangs)
        let model = try await makeLockedVault("sleep-during-unlock", stand: stand)
        let unlocking = Task { await model.unlock(password: Self.vaultPassword) }
        try await waitUntil(timeout: .seconds(60), "the vault is mounted and the mount has not returned") {
            model.disk.isOpen && stand.isHanging("attach")
        }

        model.lockBeforeSleep()

        XCTAssertFalse(model.disk.isOpen, "sleep returned before the eject")
        XCTAssertEqual(Shell.livePIDs, [], "the mount was still running when the Mac was free to sleep")
        XCTAssertEqual(model.door.state, .closed)
        XCTAssertEqual(stand.stepsForgivingABusyEject, ["attach", "eject"])
        await unlocking.value
        try await waitUntil("the lock has settled") { !model.isLocking }
        XCTAssertEqual(model.phase, .locked)
        XCTAssertFalse(model.isWorking)
    }

    func testSleepGivesUpAtItsBoundWhenTheEjectIsWedged() async throws {
        let stand = DoorStandIn()
        let model = try await makeOpenVault("sleep-bound", stand: stand, bounds: Self.shortBounds)
        stand.play("eject", as: .ignoresItsTimeLimit)
        XCTAssertEqual(model.door.bounds.lock, 0.9, accuracy: 0.001)

        let started = ContinuousClock.now
        model.lockBeforeSleep()
        let waited = ContinuousClock.now - started

        XCTAssertGreaterThan(waited, .milliseconds(850))
        XCTAssertLessThan(waited, .seconds(5), "sleep waited on the wedged eject past its bound")
        XCTAssertTrue(model.disk.isOpen)
        XCTAssertEqual(model.door.state, .closing)
        XCTAssertEqual(model.phase, .locked, "the library was back on screen while the Mac went to sleep")
    }

    // MARK: Quit

    func testQuittingLocksTheVaultThenLetsTheAppGo() async throws {
        let model = try await makeOpenVault("quit", stand: DoorStandIn())
        let preparation = QuitPreparation()
        model.quitGuard.prepare(in: preparation)

        let mayQuit = try await answerToQuit(preparation)

        XCTAssertTrue(mayQuit)
        XCTAssertFalse(model.disk.isOpen)
        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(preparation.terminateReply { _ in }, .terminateNow, "a locked vault has nothing to do before quitting")
    }

    func testQuittingDuringASlowUnlockStopsItAndLeavesNothingMounted() async throws {
        let stand = DoorStandIn()
        stand.play("attach", as: .mountsThenHangs)
        let model = try await makeLockedVault("quit-during-unlock", stand: stand)
        let preparation = QuitPreparation()
        model.quitGuard.prepare(in: preparation)
        let unlocking = Task { await model.unlock(password: Self.vaultPassword) }
        try await waitUntil(timeout: .seconds(60), "the vault is mounted and the mount has not returned") {
            model.disk.isOpen && stand.isHanging("attach")
        }

        let mayQuit = try await answerToQuit(preparation)

        XCTAssertTrue(mayQuit)
        XCTAssertFalse(model.disk.isOpen, "the app was free to quit with the vault mounted")
        XCTAssertEqual(Shell.livePIDs, [])
        XCTAssertEqual(stand.stepsForgivingABusyEject, ["attach", "eject"])
        await unlocking.value
        XCTAssertEqual(model.phase, .locked)
    }

    func testAVaultThatCannotBeLockedCancelsTheQuitOnceThenLetsTheAppGo() async throws {
        let stand = DoorStandIn()
        let model = try await makeOpenVault("cannot-lock", stand: stand)
        let state = AppState(arguments: [])
        model.quitGuard.showRefusal(on: state)
        let preparation = QuitPreparation()
        model.quitGuard.prepare(in: preparation)
        stand.play("eject", as: .fails("busy"))
        stand.play("detach", as: .fails("hdiutil: couldn't unmount \"disk9\" - Resource busy"))

        let first = try await answerToQuit(preparation)

        XCTAssertFalse(first, "the app quit with the vault still open and no warning")
        XCTAssertTrue(model.disk.isOpen)
        XCTAssertEqual(state.page, .vault)
        XCTAssertEqual(model.phase, .open)
        XCTAssertEqual(model.message, "The vault couldn't be locked, so Toolbox didn't quit. "
            + "Something is still using a file in it, for example a file open in another app. "
            + "Close what is using it, then press Lock or quit again. "
            + "Quit again to quit anyway; the vault will stay open until you eject it or restart.")

        let second = try await answerToQuit(preparation)
        XCTAssertTrue(second, "the owner asked to quit twice and was still held")
        XCTAssertTrue(model.disk.isOpen)

        model.message = nil
        let afterDismissing = try await answerToQuit(preparation)
        XCTAssertFalse(afterDismissing, "the app quit with the vault open although its warning was no longer showing")

        stand.play("eject", as: .real)
        stand.play("detach", as: .real)
        let afterItLocks = try await answerToQuit(preparation)
        XCTAssertTrue(afterItLocks)
        XCTAssertFalse(model.disk.isOpen)
        XCTAssertEqual(model.phase, .locked)
    }

    func testAQuitThatRunsOutOfPatienceWithTheVaultMountedIsRefused() async throws {
        let stand = DoorStandIn()
        let model = try await makeOpenVault("out-of-patience", stand: stand, bounds: Self.shortBounds)
        let preparation = QuitPreparation()
        model.quitGuard.prepare(in: preparation)
        stand.play("eject", as: .ignoresItsTimeLimit)
        XCTAssertEqual(model.quitGuard.patience, .seconds(2.9))

        let first = try await answerToQuit(preparation)

        XCTAssertFalse(first)
        XCTAssertTrue(model.disk.isOpen)
        XCTAssertEqual(model.message?.contains("It is taking too long to eject."), true, model.message ?? "no message")
        XCTAssertEqual(model.message?.contains("Quit again to quit anyway"), true)
        XCTAssertEqual(model.door.state, .closing)

        let second = try await answerToQuit(preparation)
        XCTAssertTrue(second, "the owner asked to quit twice and was still held")
    }

    func testAQuitDuringAPasswordChangeSaysThePasswordIsStillBeingChanged() async throws {
        let stand = DoorStandIn()
        let model = try await makeOpenVault("changing-password", stand: stand, bounds: Self.shortBounds)
        let preparation = QuitPreparation()
        model.quitGuard.prepare(in: preparation)
        stand.play("chpass", as: .hangs)
        let changing = Task { await model.changePassword(current: Self.vaultPassword, new: "newer-pass", confirmation: "newer-pass") }
        try await waitUntil("the password change is running") { stand.isHanging("chpass") && model.door.unfinishedWrite == .changingPassword }

        let first = try await answerToQuit(preparation)

        XCTAssertFalse(first)
        XCTAssertEqual(model.message, VaultNotices.quitRefused(during: .changingPassword))
        XCTAssertFalse(model.message?.contains("taking too long to eject") ?? true, "the refusal blamed the eject for waiting on the password change")
        XCTAssertEqual(model.door.unfinishedWrite, .changingPassword, "quitting stopped the password change")
        XCTAssertEqual(stand.stopped.value, [])

        model.lockBeforeSleep()
        XCTAssertEqual(model.door.unfinishedWrite, .changingPassword, "sleep stopped the password change")
        XCTAssertEqual(VaultNotices.whyNotLocked(during: model.door.unfinishedWrite, failure: model.lastLockFailure),
                       "the password is still being changed")

        let second = try await answerToQuit(preparation)
        XCTAssertTrue(second, "the owner asked to quit twice and was still held")
        changing.cancel()
    }

    func testTheReasonForAnUnfinishedLockNamesWhatItWaitsFor() {
        XCTAssertEqual(VaultNotices.whyNotLocked(during: nil, failure: nil), "the lock had not finished")
        XCTAssertEqual(VaultNotices.whyNotLocked(during: nil, failure: "Resource busy"), "Resource busy")
        XCTAssertEqual(VaultNotices.whyNotLocked(during: .changingPassword, failure: "Resource busy"), "the password is still being changed")
        XCTAssertEqual(VaultNotices.whyNotLocked(during: .creating, failure: nil), "the vault is still being created")
    }

    func testQuittingWhileTheVaultIsBeingCreatedNeverStopsTheCreation() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("create"))
        let pidFile = dir.appendingPathComponent("create.pid")
        let verbs = Locked<[String]>([])
        let child = Locked<Int32?>(nil)
        killAfterTest(child)
        let tool = VaultTool { path, arguments, input, timeout in
            verbs.update { $0.append(arguments.first { DoorStandIn.verbs.contains($0) } ?? path) }
            guard arguments.contains("create"), timeout == .untilFinished else { throw Shell.ShellError.launchFailed(path) }
            let script = "cat > /dev/null; echo $$ > \"$1\"; /bin/sleep 4; /bin/mkdir \"$2\""
            return try await VaultTool.system.run("/bin/sh", ["-c", script, "sh", pidFile.path, arguments.last ?? ""], input, timeout)
        }
        let model = VaultModel(location: location, watchesSystem: false, tool: tool, bounds: Self.shortBounds, anotherCopyIsRunning: { false })
        let preparation = QuitPreparation()
        model.quitGuard.prepare(in: preparation)
        let creating = Task { await model.create(password: Self.vaultPassword, confirmation: Self.vaultPassword) }
        try await waitUntil("the stand-in for diskutil create is running") {
            child.set((try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
            return child.value != nil
        }
        let pid = try XCTUnwrap(child.value)
        XCTAssertLessThan(model.quitGuard.patience, .seconds(4), "the stand-in has to outlast the quit's patience")

        let mayQuit = try await answerToQuit(preparation)
        Shell.stopChildrenBeforeQuit(grace: 0.2)

        XCTAssertFalse(mayQuit, "the app quit before the new vault was moved into place, so the vault would be lost")
        XCTAssertEqual(model.message, VaultNotices.quitRefused(during: .creating))
        XCTAssertTrue(isRunning(pid), "creating the vault was stopped by quitting")
        await creating.value
        XCTAssertTrue(model.disk.exists)
        XCTAssertEqual(verbs.value, ["create"], "a vault created while the app was quitting was mounted afterwards")
        XCTAssertFalse(model.disk.isOpen)
        XCTAssertNil(model.message, "the refusal still asked to wait for a creation that had finished")
        XCTAssertTrue(model.quitGuard.mayQuit())
    }

    func testAFailedUnlockThatLeavesTheVaultMountedSaysSo() async throws {
        let stand = DoorStandIn()
        let model = try await makeLockedVault("left-mounted", stand: stand)
        stand.play("attach", as: .mountsThenFails("the attach went wrong late"))
        stand.play("eject", as: .fails("busy"))
        stand.play("detach", as: .fails("hdiutil: couldn't unmount \"disk9\" - Resource busy"))

        await model.unlock(password: Self.vaultPassword)

        XCTAssertTrue(model.disk.isOpen)
        XCTAssertEqual(model.door.state, .open)
        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(model.message, VaultNotices.leftMountedByFailedUnlock, "the owner was not told the vault is still readable")
        XCTAssertFalse(model.quitGuard.mayQuit(), "the app could quit without a word with the vault mounted")
    }

    func testTheRefusalSaysWhatMacOSSaidWhenNothingIsKnownToUseTheVault() {
        XCTAssertTrue(VaultNotices.quitRefused(reason: "The disk went away").contains("macOS said: The disk went away"))
        XCTAssertTrue(VaultNotices.quitRefused(reason: nil).contains("Quit again to quit anyway; the vault will stay open until you eject it or restart."))
    }

    // MARK: Helpers

    private func answerToQuit(_ preparation: QuitPreparation) async throws -> Bool {
        var answer: Bool?
        XCTAssertEqual(preparation.terminateReply { answer = $0 }, .terminateLater)
        try await waitUntil(timeout: .seconds(60), "the quit was answered") { answer != nil }
        return try XCTUnwrap(answer)
    }

    private func makeLockedVault(_ name: String, stand: DoorStandIn, bounds: VaultDoor.Bounds = VaultDoor.Bounds()) async throws -> VaultModel {
        let location = VaultLocation(folder: dir.appendingPathComponent(name))
        try await makeVaultImage(in: location.folder)
        let model = VaultModel(location: location, watchesSystem: false, tool: stand.tool, bounds: bounds, anotherCopyIsRunning: { false })
        addTeardownBlock { @MainActor in
            for verb in DoorStandIn.verbs { stand.play(verb, as: .real) }
            for verb in ["eject", "detach"] { stand.play(verb, as: .realWithRoomToFinish) }
            Shell.livePIDs.forEach { kill($0, SIGKILL) }
            await model.lock()
            await Self.detachWhateverIsLeft(at: model.disk)
            _ = model.lockIfClosedFromOutside()
        }
        XCTAssertEqual(model.phase, .locked)
        return model
    }

    private func makeOpenVault(_ name: String, stand: DoorStandIn, bounds: VaultDoor.Bounds = VaultDoor.Bounds()) async throws -> VaultModel {
        let model = try await makeLockedVault(name, stand: stand, bounds: bounds)
        await model.unlock(password: Self.vaultPassword)
        model.finishOpening()
        XCTAssertEqual(model.phase, .open, model.message ?? "")
        return model
    }
}
