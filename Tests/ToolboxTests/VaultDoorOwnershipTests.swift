import XCTest
@testable import Toolbox

/// Two doors on one folder stand for two copies of the app: `flock` belongs to the open file, not to the process.
final class VaultDoorOwnershipTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeVaultTestFolder("owner")
    }

    private func folder(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private func lockFile(in folder: URL) -> URL { folder.appendingPathComponent(VaultDoor.lockFileName) }

    // MARK: The lock file

    func testASecondCopyIsRefusedWhileTheFirstHasTheVaultOpenAndRunsNoTool() async throws {
        let first = try await makeOpenDoor(in: folder("shared"))
        let stand = DoorStandIn()
        let second = makeDoor(in: folder("shared"), tool: stand.tool)
        XCTAssertEqual(second.state, .openElsewhere)

        let unlock = await second.unlock(password: Self.vaultPassword)
        let lock = await second.lock()
        let recovery = await second.recoverAtLaunch()
        let change = await second.changePassword(from: Self.vaultPassword, to: "other-pass")

        XCTAssertEqual(unlock, .refused(.openInAnotherCopy))
        XCTAssertEqual(lock, .notOurs)
        XCTAssertEqual(recovery, .notOurs)
        XCTAssertEqual(change, .openInAnotherCopy)
        XCTAssertEqual(stand.steps.value, [], "a copy that does not own the vault ran a disk tool on it")
        XCTAssertFalse(second.holdsOwnership)
        XCTAssertFalse(second.noticeOutsideEject())
        XCTAssertTrue(first.disk.isOpen, "the second copy ejected the first copy's vault")
        XCTAssertEqual(first.state, .open)
        XCTAssertEqual(VaultError.openInAnotherCopy.localizedDescription, "The vault is open in another copy of Toolbox. Lock it there first.")
    }

    func testTheLockFileIsGivenUpWhenTheVaultIsLocked() async throws {
        let first = try await makeOpenDoor(in: folder("handover"))
        let second = makeDoor(in: folder("handover"))
        let holder = try String(contentsOf: lockFile(in: folder("handover")), encoding: .utf8)
        XCTAssertTrue(holder.hasPrefix("\(getpid()) "), "the lock file does not say who holds it: \(holder)")

        let locked = await first.lock()
        let opened = await second.unlock(password: Self.vaultPassword)

        XCTAssertEqual(locked, .locked)
        XCTAssertEqual(opened, .opened)
        XCTAssertTrue(second.holdsOwnership)
        let refused = await first.unlock(password: Self.vaultPassword)
        XCTAssertEqual(refused, .refused(.openInAnotherCopy))
        XCTAssertTrue(second.disk.isOpen)
    }

    func testALockFileLeftByACopyThatIsGoneIsTakenOver() async throws {
        try await makeVaultImage(in: folder("stale"))
        try Data("99999999 1\n".utf8).write(to: lockFile(in: folder("stale")))
        let door = makeDoor(in: folder("stale"))

        let opened = await door.unlock(password: Self.vaultPassword)

        XCTAssertEqual(opened, .opened)
        let holder = try String(contentsOf: lockFile(in: folder("stale")), encoding: .utf8)
        XCTAssertTrue(holder.hasPrefix("\(getpid()) "), holder)
    }

    func testADoorThatGoesAwayGivesUpTheLockFileAndItsLeftoverIsRecovered() async throws {
        try await makeVaultImage(in: folder("gone"))
        var crashed: VaultDoor? = VaultDoor(location: VaultLocation(folder: folder("gone")), anotherCopyIsRunning: { false })
        let opened = await crashed?.unlock(password: Self.vaultPassword)
        XCTAssertEqual(opened, .opened)
        crashed = nil

        let stand = DoorStandIn()
        let next = makeDoor(in: folder("gone"), tool: stand.tool)
        XCTAssertEqual(next.state, .openElsewhere)
        XCTAssertTrue(next.disk.isOpen)

        let recovered = await next.recoverAtLaunch()

        XCTAssertEqual(recovered, .locked)
        XCTAssertEqual(stand.stepsForgivingABusyEject, ["eject"])
        XCTAssertFalse(next.disk.isOpen)
        XCTAssertEqual(next.state, .closed)
        XCTAssertFalse(next.holdsOwnership)
    }

    func testAMountNobodyClaimsIsLeftAloneWhileAnotherCopyRuns() async throws {
        try await makeVaultImage(in: folder("old-copy"))
        var olderCopy: VaultDoor? = VaultDoor(location: VaultLocation(folder: folder("old-copy")), anotherCopyIsRunning: { false })
        let opened = await olderCopy?.unlock(password: Self.vaultPassword)
        XCTAssertEqual(opened, .opened)
        olderCopy = nil
        let stand = DoorStandIn()
        let door = makeDoor(in: folder("old-copy"), tool: stand.tool, anotherCopyIsRunning: { true })

        let recovery = await door.recoverAtLaunch()
        let unlock = await door.unlock(password: Self.vaultPassword)
        let lock = await door.lock()

        XCTAssertEqual(recovery, .notOurs)
        XCTAssertEqual(unlock, .refused(.openInAnotherCopy))
        XCTAssertEqual(lock, .notOurs)
        XCTAssertEqual(stand.steps.value, [], "a copy without the lock file may be an older version using this vault")
        XCTAssertTrue(door.disk.isOpen)
        XCTAssertFalse(door.holdsOwnership)
        XCTAssertEqual(door.state, .openElsewhere)
    }

    func testAFailedUnlockNeverEjectsAMountWhileAnotherCopyIsRunning() async throws {
        try await makeVaultImage(in: folder("two-unlocks"))
        let steps = Locked<[String]>([])
        let mountsThenFails = VaultTool { path, arguments, input, timeout in
            steps.update { $0.append(arguments.first { DoorStandIn.verbs.contains($0) } ?? path) }
            let result = try await VaultTool.system.run(path, arguments, input, timeout)
            guard arguments.contains("attach") else { return result }
            return Shell.Result(status: 1, out: "", err: "the other copy's attach won")
        }
        let door = makeDoor(in: folder("two-unlocks"), tool: mountsThenFails, anotherCopyIsRunning: { true })

        let outcome = await door.unlock(password: Self.vaultPassword)

        XCTAssertEqual(outcome, .refused(.diskTool(action: "open", message: "the other copy's attach won")))
        XCTAssertTrue(door.disk.isOpen, "a failed unlock ejected the vault another copy had just opened")
        XCTAssertEqual(steps.value, ["attach"])
        XCTAssertEqual(door.state, .openElsewhere)
        XCTAssertFalse(door.holdsOwnership)
        let lock = await door.lock()
        XCTAssertEqual(lock, .notOurs)
        XCTAssertTrue(door.disk.isOpen)
    }

    func testCreatingNeverTouchesAVaultThatIsAlreadyThere() async throws {
        let location = VaultLocation(folder: folder("already-there"))
        try Self.writeImage(at: location.image.path, holding: "someone's vault")
        let ran = Locked(false)
        let door = makeDoor(in: location.folder, tool: VaultTool { path, _, _, _ in
            ran.set(true)
            throw Shell.ShellError.launchFailed(path)
        })

        let refusal = await door.create(password: "new-pass")

        XCTAssertEqual(refusal, .alreadyExists)
        XCTAssertFalse(ran.value)
        XCTAssertEqual(try String(contentsOf: location.image.appendingPathComponent("band"), encoding: .utf8), "someone's vault")
    }

    func testTwoCopiesUnlockingAtTheSameInstantLeaveExactlyOneOpen() async throws {
        try await makeVaultImage(in: folder("same-instant"))
        let firstStand = DoorStandIn()
        let secondStand = DoorStandIn()
        let first = makeDoor(in: folder("same-instant"), tool: firstStand.tool, anotherCopyIsRunning: { true })
        let second = makeDoor(in: folder("same-instant"), tool: secondStand.tool, anotherCopyIsRunning: { true })

        async let one = first.unlock(password: Self.vaultPassword)
        async let two = second.unlock(password: Self.vaultPassword)
        let outcomes = await [one, two]

        XCTAssertEqual(outcomes.filter { $0 == .opened }.count, 1, "\(outcomes)")
        XCTAssertEqual(outcomes.filter { $0 == .refused(.openInAnotherCopy) }.count, 1, "\(outcomes)")
        let (winner, loser) = first.state == .open ? (first, second) : (second, first)
        let losersTools = first.state == .open ? secondStand : firstStand
        XCTAssertEqual(winner.state, .open)
        XCTAssertTrue(winner.disk.isOpen, "the copy that lost ejected the winner's vault")
        XCTAssertEqual(losersTools.steps.value, [], "the copy that lost ran a disk tool")
        XCTAssertFalse(loser.holdsOwnership)
        let lock = await loser.lock()
        XCTAssertTrue([.locked, .notOurs].contains(lock), "\(lock)")
        XCTAssertTrue(winner.disk.isOpen)
    }

    // MARK: Writes that are never cut short

    func testCreatingTheVaultIsNeverStoppedAndALockDoesNotWaitForIt() async throws {
        let (tool, started) = try slowWrite(of: "create", then: "/bin/mkdir \"$2\"", finishing: nil)
        let seen = Locked<[Shell.Timeout]>([])
        let door = makeDoor(in: folder("slow-create"), tool: VaultTool { path, arguments, input, timeout in
            seen.update { $0.append(timeout) }
            return try await tool.run(path, arguments, input, timeout)
        })

        let creating = Task.detached { await door.create(password: "slow-pass") }
        let pid = try await started()
        creating.cancel()
        let locked = await door.lock()
        Shell.stopChildrenBeforeQuit(grace: 0.2)

        XCTAssertEqual(locked, .locked, "a lock waited for a creation although nothing is mounted")
        XCTAssertTrue(isRunning(pid), "creating the vault was stopped halfway")
        let refusal = await creating.value
        XCTAssertNil(refusal)
        XCTAssertTrue(door.disk.exists)
        XCTAssertEqual(unfinishedImages(in: folder("slow-create")), [])
        XCTAssertEqual(seen.value, [.untilFinished])
    }

    func testChangingThePasswordIsNeverStoppedAndALockWaitsItsTurnBehindIt() async throws {
        let done = dir.appendingPathComponent("password-changed").path
        let (slow, started) = try slowWrite(of: "chpass", then: "/usr/bin/touch \"$2\"", finishing: done)
        let seen = Locked<[String: Shell.Timeout]>([:])
        let door = try await makeOpenDoor(in: folder("slow-password"), tool: VaultTool { path, arguments, input, timeout in
            guard arguments.contains("chpass") else { return try await VaultTool.system.run(path, arguments, input, timeout) }
            seen.update { $0["chpass"] = timeout }
            return try await slow.run(path, arguments, input, timeout)
        })

        let changing = Task.detached { await door.changePassword(from: "old-pass", to: "new-pass") }
        let pid = try await started()
        changing.cancel()
        let pending = door.startLock()
        Shell.stopChildrenBeforeQuit(grace: 0.2)

        XCTAssertNil(pending.wait(upTo: 0.3), "the lock ran while the password was still being changed")
        XCTAssertTrue(isRunning(pid), "changing the password was stopped halfway")
        XCTAssertTrue(door.disk.isOpen)
        let refusal = await changing.value
        let locked = await pending.value()
        XCTAssertNil(refusal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: done))
        XCTAssertEqual(locked, .locked)
        XCTAssertFalse(door.disk.isOpen)
        XCTAssertEqual(seen.value, ["chpass": .untilFinished])
    }

    func testACreationThatFailsRemovesOnlyItsOwnUnfinishedImage() async throws {
        let location = VaultLocation(folder: folder("half-made"))
        let cannotStart = makeDoor(in: location.folder, tool: VaultTool { path, arguments, _, _ in
            try Self.writeImage(at: arguments.last, holding: "partial")
            throw Shell.ShellError.launchFailed(path)
        })
        let failsWhileAnotherCopyMakesTheVault = makeDoor(in: location.folder, tool: VaultTool { _, arguments, _, _ in
            try Self.writeImage(at: arguments.last, holding: "partial")
            try Self.writeImage(at: location.image.path, holding: "another copy's vault")
            return Shell.Result(status: 1, out: "", err: "disk full")
        })

        let thrown = await cannotStart.create(password: "half-pass")
        XCTAssertEqual(thrown, .diskTool(action: "be created", message: "Could not start diskutil."))
        XCTAssertFalse(cannotStart.disk.exists)
        XCTAssertEqual(unfinishedImages(in: location.folder), [])

        let failed = await failsWhileAnotherCopyMakesTheVault.create(password: "half-pass")
        XCTAssertEqual(failed, .diskTool(action: "be created", message: "disk full"))
        XCTAssertEqual(unfinishedImages(in: location.folder), [])
        XCTAssertEqual(try String(contentsOf: location.image.appendingPathComponent("band"), encoding: .utf8), "another copy's vault")
    }

    func testAVaultThatAppearedWhileThisOneWasBeingMadeIsNeverReplaced() async throws {
        let location = VaultLocation(folder: folder("raced"))
        let made = Locked<[String]>([])
        let door = makeDoor(in: location.folder, tool: VaultTool { _, arguments, _, _ in
            made.update { $0.append(arguments.last ?? "") }
            try Self.writeImage(at: arguments.last, holding: "this copy's new image")
            try Self.writeImage(at: location.image.path, holding: "another copy's vault")
            return Shell.Result(status: 0, out: "", err: "")
        })

        let refusal = await door.create(password: "raced-pass")

        XCTAssertEqual(refusal, .alreadyExists)
        let target = try XCTUnwrap(made.value.first)
        XCTAssertTrue(URL(fileURLWithPath: target).lastPathComponent.hasPrefix(VaultDisk.unfinishedPrefix), "the tool was pointed at \(target)")
        XCTAssertEqual(unfinishedImages(in: location.folder), [])
        XCTAssertEqual(try String(contentsOf: location.image.appendingPathComponent("band"), encoding: .utf8), "another copy's vault")
    }

    func testAnUnfinishedImageLeftByACrashIsIgnoredAndRemovedOnceItIsOld() async throws {
        let location = VaultLocation(folder: folder("leftover"))
        let old = location.folder.appendingPathComponent("\(VaultDisk.unfinishedPrefix)OLD\(VaultDisk.unfinishedSuffix)")
        let recent = location.folder.appendingPathComponent("\(VaultDisk.unfinishedPrefix)RECENT\(VaultDisk.unfinishedSuffix)")
        for image in [old, recent] { try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true) }
        let longAgo = Date(timeIntervalSinceNow: -2 * VaultDisk.unfinishedIsAbandonedAfter)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)
        let ran = Locked(false)
        let door = makeDoor(in: location.folder, tool: VaultTool { _, arguments, _, _ in
            ran.set(true)
            try Self.writeImage(at: arguments.last, holding: "new")
            return Shell.Result(status: 0, out: "", err: "")
        })
        XCTAssertFalse(door.disk.exists, "an unfinished image counted as a vault")

        let refusal = await door.create(password: "fresh-pass")

        XCTAssertNil(refusal)
        XCTAssertTrue(door.disk.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "another copy may still be creating this one")
        let again = await door.create(password: "fresh-pass")
        XCTAssertEqual(again, .alreadyExists)
        XCTAssertTrue(ran.value)
    }

    // MARK: Helpers

    private static func writeImage(at path: String?, holding text: String) throws {
        let image = URL(fileURLWithPath: try XCTUnwrap(path), isDirectory: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: image.appendingPathComponent("band"))
    }

    private func unfinishedImages(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(VaultDisk.unfinishedPrefix) }
    }

    /// A stand-in for a diskutil write that takes a second and a half, and a way to wait until it is running.
    private func slowWrite(of verb: String, then finish: String, finishing: String?) throws -> (VaultTool, @MainActor () async throws -> Int32) {
        let pidFile = dir.appendingPathComponent("\(verb).pid")
        let child = Locked<Int32?>(nil)
        killAfterTest(child)
        let script = "cat > /dev/null; echo $$ > \"$1\"; /bin/sleep 1.5; \(finish)"
        let tool = VaultTool { _, arguments, input, timeout in
            try await VaultTool.system.run("/bin/sh", ["-c", script, "sh", pidFile.path, finishing ?? arguments.last ?? ""], input, timeout)
        }
        return (tool, {
            try await waitUntil("the stand-in for diskutil \(verb) is running") {
                child.set((try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
                return child.value != nil
            }
            return try XCTUnwrap(child.value)
        })
    }
}
