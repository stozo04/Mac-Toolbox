import XCTest
@testable import Toolbox

final class VaultDiskTests: XCTestCase {
    private static let password = "disk-pass"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-disk-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        killProgramsLeftRunning()
    }

    func testTheRefusalNamesTheFolderAndSaysWhatToDo() {
        let message = VaultError.filesLeftOutside(count: 3, folder: "~/Vault/Open.noindex").localizedDescription

        XCTAssertTrue(message.contains("3 files were found in the vault's open folder, outside the vault"), message)
        XCTAssertTrue(message.contains("~/Vault/Open.noindex"), message)
        XCTAssertTrue(message.contains("Move them somewhere else, then unlock again."), message)
    }

    func testUnlockDoesNotMindAMissingOpenFolder() async throws {
        let disk = VaultDisk(location: VaultLocation(folder: dir.appendingPathComponent("no-folder")))
        try await disk.create(password: "plain-pass")
        addTeardownBlock { disk.lockAndWait() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.location.mountPoint.path))

        try await disk.unlock(password: "plain-pass")

        XCTAssertTrue(disk.isOpen)
    }

    @MainActor
    func testTheDoorOffersTheFolderOnlyWhileFilesAreLeftInIt() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("door"))
        try await VaultDisk(location: location).create(password: Self.password)
        try FileManager.default.createDirectory(at: location.mountPoint, withIntermediateDirectories: false)
        let stray = location.mountPoint.appendingPathComponent("stray.png")
        try Data("left outside".utf8).write(to: stray)
        let model = VaultModel(location: location, watchesSystem: false)
        addTeardownBlock { @MainActor in model.lockImmediately() }

        await model.unlock(password: Self.password)

        XCTAssertEqual(model.folderWithFilesLeftOutside, location.mountPoint)
        XCTAssertEqual(model.message?.contains("Move it somewhere else, then unlock again."), true, model.message ?? "no message")
        XCTAssertFalse(model.disk.isOpen)

        try FileManager.default.removeItem(at: stray)
        await model.unlock(password: Self.password)

        XCTAssertNil(model.folderWithFilesLeftOutside)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.disk.isOpen)
    }

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
        XCTAssertNotEqual(VaultLocation.development.mountPoint, VaultLocation.standard.mountPoint)
        XCTAssertNotEqual(VaultLocation.development.image, VaultLocation.standard.image)
    }

    @MainActor
    func testAVaultAnotherCopyHasOpenIsNeverEjectedByThisCopy() async throws {
        let disk = try await makeOpenDisk("other-copy")
        let steps = Locked<[String]>([])
        let recording = VaultTool { path, arguments, input, timeout in
            steps.update { $0.append(arguments.first ?? path) }
            return try await VaultTool.system.run(path, arguments, input, timeout)
        }

        let model = VaultModel(location: disk.location, watchesSystem: false, tool: recording, anotherCopyIsRunning: { true })

        XCTAssertTrue(disk.isOpen, "launching a second copy ejected the vault the first copy is using")
        XCTAssertFalse(model.ownsMount)
        await model.lock()
        XCTAssertTrue(disk.isOpen, "the Lock button or leaving the Vault page ejected another copy's vault")
        model.lockImmediately()
        XCTAssertTrue(disk.isOpen, "sleep, screen lock or quit ejected another copy's vault")
        XCTAssertEqual(model.phase, .locked)
        XCTAssertNil(model.message)

        await model.unlock(password: Self.password)

        XCTAssertEqual(model.message, "The vault is open in another copy of Toolbox. Lock it there first.")
        XCTAssertEqual(model.phase, .locked)
        XCTAssertFalse(model.ownsMount)
        XCTAssertTrue(disk.isOpen, "unlocking ejected another copy's vault first")
        XCTAssertEqual(steps.value, [], "this copy ran a disk tool on a vault another copy is using")
    }

    @MainActor
    func testAVaultLeftOpenWithNoOtherCopyRunningIsLockedAtLaunchAndOpensAgain() async throws {
        let disk = try await makeOpenDisk("left-open")

        let model = VaultModel(location: disk.location, watchesSystem: false, anotherCopyIsRunning: { false })

        XCTAssertFalse(disk.isOpen)
        XCTAssertEqual(model.phase, .locked)
        await model.unlock(password: Self.password)
        XCTAssertTrue(disk.isOpen)
        XCTAssertTrue(model.ownsMount)
        model.lockImmediately()
        XCTAssertFalse(disk.isOpen)
        XCTAssertFalse(model.ownsMount)
    }

    @MainActor
    func testThisCopyOwnsTheMountOnlyOnceItsOwnAttachSucceeded() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("ownership"))
        try await VaultDisk(location: location).create(password: Self.password)
        let ownedDuringAttach = Locked<[Bool]>([])
        let model = Locked<VaultModel?>(nil)
        let watching = VaultTool { path, arguments, input, timeout in
            let result = try await VaultTool.system.run(path, arguments, input, timeout)
            if arguments.contains("attach") {
                let owned = await MainActor.run { model.value?.ownsMount ?? true }
                ownedDuringAttach.update { $0.append(owned) }
            }
            return result
        }
        let vault = VaultModel(location: location, watchesSystem: false, tool: watching, anotherCopyIsRunning: { true })
        model.set(vault)
        addTeardownBlock { @MainActor in vault.lockImmediately() }

        await vault.unlock(password: "wrong-pass")
        XCTAssertFalse(vault.ownsMount, "a failed attach counted as this copy's mount")
        XCTAssertFalse(vault.disk.isOpen)

        await vault.unlock(password: Self.password)
        XCTAssertTrue(vault.ownsMount)
        XCTAssertTrue(vault.disk.isOpen)

        XCTAssertEqual(ownedDuringAttach.value, [false, false], "the mount counted as owned before the attach had returned")

        await vault.lock()
        XCTAssertFalse(vault.disk.isOpen, "this copy did not eject its own mount while another copy was running")
        XCTAssertFalse(vault.ownsMount)
    }

    func testUnlockRefusesAMountPointThatAlreadyHoldsFiles() async throws {
        let disk = VaultDisk(location: VaultLocation(folder: dir.appendingPathComponent("stray")))
        try await disk.create(password: Self.password)
        addTeardownBlock { disk.lockAndWait() }
        let mountPoint = disk.location.mountPoint
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        let stray = mountPoint.appendingPathComponent("stray.png")
        try Data("left outside".utf8).write(to: stray)
        let folder = (mountPoint.path as NSString).abbreviatingWithTildeInPath

        do {
            try await disk.unlock(password: Self.password)
            XCTFail("The vault was mounted over an unprotected file, hiding it")
        } catch {
            XCTAssertEqual(error as? VaultError, .filesLeftOutside(count: 1, folder: folder))
            XCTAssertEqual(error.localizedDescription,
                           "1 file was found in the vault's open folder, outside the vault: \(folder). Move it somewhere else, then unlock again.")
        }
        XCTAssertFalse(disk.isOpen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))

        try FileManager.default.removeItem(at: stray)
        try Data().write(to: mountPoint.appendingPathComponent(".DS_Store"))
        try Data().write(to: mountPoint.appendingPathComponent(VaultDisk.spotlightOptOut))
        try await disk.unlock(password: Self.password)
        XCTAssertTrue(disk.isOpen)
    }

    func testAToolThatIgnoresBeingAskedToStopIsKilledAtItsTimeout() async {
        let started = ContinuousClock.now
        do {
            _ = try await VaultTool.system.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 30"], nil, .seconds(0.2))
            XCTFail("The 30 second tool returned a result")
        } catch {
            XCTAssertEqual(error as? Shell.ShellError, .timedOut("/bin/sh", 0.2))
            XCTAssertTrue(error.localizedDescription.contains("did not finish"), error.localizedDescription)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(15), "the 30 second tool wasn't stopped")
        XCTAssertEqual(Shell.livePIDs, [])
    }

    func testAToolsOutputAndStatusComeBack() async throws {
        let result = try await VaultTool.system.run("/bin/sh", ["-c", "cat; echo problem >&2; exit 3"], Data("typed".utf8), .quick)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.out, "typed")
        XCTAssertEqual(result.err, "problem\n")
        do {
            _ = try await VaultTool.system.run("/nonexistent/tool", [], nil, .quick)
            XCTFail("A tool that isn't there ran")
        } catch {
            XCTAssertEqual(error as? Shell.ShellError, .launchFailed("/nonexistent/tool"))
        }
    }

    @MainActor
    func testCreatingTheVaultIsNeverCutShort() async throws {
        let disk = VaultDisk(location: VaultLocation(folder: dir.appendingPathComponent("slow-create")))
        let stand = try standIn(for: "create", script: "cat > /dev/null; echo $$ > \"$1\"; /bin/sleep 1; /bin/mkdir \"$2\"", finishing: nil)
        var slow = disk
        slow.tool = stand.tool

        let creating = Task.detached { [slow] in try await slow.create(password: "slow-pass") }
        let pid = try await stand.waitUntilRunning()
        creating.cancel()
        Shell.stopChildrenBeforeQuit(grace: 0.2)

        XCTAssertTrue(isRunning(pid), "creating the vault was stopped halfway")
        try await creating.value
        XCTAssertTrue(disk.exists)
        XCTAssertEqual(unfinishedImages(in: disk.location), [])
        XCTAssertEqual(stand.timeouts.value, [.untilFinished])
    }

    @MainActor
    func testChangingThePasswordIsNeverCutShort() async throws {
        let disk = VaultDisk(location: VaultLocation(folder: dir.appendingPathComponent("slow-password")))
        let finished = dir.appendingPathComponent("password-changed").path
        let stand = try standIn(for: "chpass", script: "cat > /dev/null; echo $$ > \"$1\"; /bin/sleep 1; /usr/bin/touch \"$2\"", finishing: finished)
        var slow = disk
        slow.tool = stand.tool

        let changing = Task.detached { [slow] in try await slow.changePassword(from: "old-pass", to: "new-pass") }
        let pid = try await stand.waitUntilRunning()
        changing.cancel()
        Shell.stopChildrenBeforeQuit(grace: 0.2)

        XCTAssertTrue(isRunning(pid), "changing the password was stopped halfway")
        try await changing.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished))
        XCTAssertEqual(stand.timeouts.value, [.untilFinished])
    }

    func testOnlyMountingAndEjectingHaveATimeLimitAndNothingEndsWithTheApp() async throws {
        let seen = Locked<[String: Shell.Timeout]>([:])
        let recording = VaultTool { path, arguments, input, timeout in
            let verb = arguments.first { ["create", "attach", "chpass", "eject", "detach"].contains($0) } ?? path
            seen.update { $0[verb] = timeout }
            return try await VaultTool.system.run(path, arguments, input, timeout)
        }
        let disk = VaultDisk(location: VaultLocation(folder: dir.appendingPathComponent("limits")), tool: recording)
        addTeardownBlock { disk.lockAndWait() }

        try await disk.create(password: "first-pass")
        try await disk.changePassword(from: "first-pass", to: "second-pass")
        try await disk.unlock(password: "second-pass")
        try await disk.lock()

        XCTAssertFalse(disk.isOpen)
        XCTAssertEqual(seen.value, ["create": .untilFinished, "chpass": .untilFinished,
                                    "attach": .diskImage, "eject": .diskImage])
        XCTAssertFalse(seen.value.values.contains(.untilCancelled), "quitting stops programs that run until cancelled")
    }

    func testAnEjectThatTimesOutStillForcesTheVaultClosed() async throws {
        let disk = try await makeOpenDisk("stuck-eject")
        let steps = Locked<[String]>([])
        var stuck = disk
        stuck.tool = VaultTool { path, arguments, input, timeout in
            steps.update { $0.append(arguments.first ?? path) }
            if arguments.first == "eject" { throw Shell.ShellError.timedOut(path, 300) }
            return try await VaultTool.system.run(path, arguments, input, timeout)
        }

        try await stuck.lock()

        XCTAssertEqual(steps.value, ["eject", "detach"])
        XCTAssertFalse(disk.isOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.location.mountPoint.path))
    }

    func testAMountThatTimesOutAfterAttachingIsClosedAgain() async throws {
        let disk = VaultDisk(location: VaultLocation(folder: dir.appendingPathComponent("half-mounted")))
        try await disk.create(password: "half-pass")
        addTeardownBlock { disk.lockAndWait() }
        let attached = Locked(false)
        var slow = disk
        slow.tool = VaultTool { path, arguments, input, timeout in
            let result = try await VaultTool.system.run(path, arguments, input, timeout)
            guard arguments.contains("attach") else { return result }
            attached.set(disk.isOpen)
            throw Shell.ShellError.timedOut(path, 300)
        }

        do {
            try await slow.unlock(password: "half-pass")
            XCTFail("A mount that timed out counted as open")
        } catch {
            XCTAssertEqual(error as? VaultError, .diskTool(action: "open", message: "diskutil did not finish within 300 seconds, so it was stopped."))
        }

        XCTAssertTrue(attached.value, "the stand-in never mounted the vault, so nothing was proved")
        XCTAssertFalse(disk.isOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.location.mountPoint.path))
    }

    func testAMountThatCannotStartLeavesNoFolderBehind() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("no-start"))
        try FileManager.default.createDirectory(at: location.folder, withIntermediateDirectories: true)
        let disk = VaultDisk(location: location, tool: VaultTool { path, _, _, _ in throw Shell.ShellError.launchFailed(path) })

        do {
            try await disk.unlock(password: "any-pass")
            XCTFail("A mount that never started counted as open")
        } catch {
            XCTAssertEqual(error as? VaultError, .diskTool(action: "open", message: "Could not start diskutil."))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: location.mountPoint.path))
    }

    func testACreationThatFailsRemovesOnlyItsOwnUnfinishedImage() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("half-made"))
        let thrown = VaultDisk(location: location, tool: VaultTool { path, arguments, _, _ in
            try Self.writeImage(at: arguments.last, holding: "partial")
            throw Shell.ShellError.launchFailed(path)
        })
        let failedWhileAnotherCopyMadeTheVault = VaultDisk(location: location, tool: VaultTool { _, arguments, _, _ in
            try Self.writeImage(at: arguments.last, holding: "partial")
            try Self.writeImage(at: location.image.path, holding: "another copy's vault")
            return Shell.Result(status: 1, out: "", err: "disk full")
        })

        do {
            try await thrown.create(password: "half-pass")
            XCTFail("A creation that threw counted as done")
        } catch {
            XCTAssertEqual(error as? VaultError, .diskTool(action: "be created", message: "Could not start diskutil."))
        }
        XCTAssertFalse(thrown.exists)
        XCTAssertEqual(unfinishedImages(in: location), [])

        do {
            try await failedWhileAnotherCopyMadeTheVault.create(password: "half-pass")
            XCTFail("A creation that failed counted as done")
        } catch {
            XCTAssertEqual(error as? VaultError, .diskTool(action: "be created", message: "disk full"))
        }
        XCTAssertEqual(unfinishedImages(in: location), [])
        XCTAssertEqual(try String(contentsOf: location.image.appendingPathComponent("band"), encoding: .utf8), "another copy's vault")
    }

    func testAVaultThatAppearedWhileThisOneWasBeingMadeIsNeverReplaced() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("raced"))
        let made = Locked<[String]>([])
        let disk = VaultDisk(location: location, tool: VaultTool { _, arguments, _, timeout in
            made.update { $0.append(arguments.last ?? "") }
            XCTAssertEqual(timeout, .untilFinished)
            try Self.writeImage(at: arguments.last, holding: "this copy's new image")
            try Self.writeImage(at: location.image.path, holding: "another copy's vault")
            return Shell.Result(status: 0, out: "", err: "")
        })

        do {
            try await disk.create(password: "raced-pass")
            XCTFail("A vault another copy had just made was replaced")
        } catch {
            XCTAssertEqual(error as? VaultError, .alreadyExists)
        }

        let target = try XCTUnwrap(made.value.first)
        XCTAssertNotEqual(target, location.image.path, "the tool was pointed at the real image path")
        XCTAssertTrue(URL(fileURLWithPath: target).lastPathComponent.hasPrefix(VaultDisk.unfinishedPrefix))
        XCTAssertEqual(unfinishedImages(in: location), [])
        XCTAssertEqual(try String(contentsOf: location.image.appendingPathComponent("band"), encoding: .utf8), "another copy's vault")
    }

    func testARealCreationLeavesTheImageInPlaceAndNothingUnfinished() async throws {
        let disk = try await makeOpenDisk("in-place")

        XCTAssertTrue(disk.exists)
        XCTAssertEqual(unfinishedImages(in: disk.location), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.location.mountPoint.appendingPathComponent(VaultDisk.spotlightOptOut).path))
    }

    func testAnUnfinishedImageLeftByACrashIsIgnoredAndRemovedOnceItIsOld() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("leftover"))
        let old = location.folder.appendingPathComponent("\(VaultDisk.unfinishedPrefix)OLD\(VaultDisk.unfinishedSuffix)")
        let recent = location.folder.appendingPathComponent("\(VaultDisk.unfinishedPrefix)RECENT\(VaultDisk.unfinishedSuffix)")
        let unrelated = location.folder.appendingPathComponent("Keep.sparsebundle")
        for image in [old, recent, unrelated] {
            try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        }
        let longAgo = Date(timeIntervalSinceNow: -2 * VaultDisk.unfinishedIsAbandonedAfter)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: unrelated.path)
        let disk = VaultDisk(location: location, tool: VaultTool { _, arguments, _, _ in
            try Self.writeImage(at: arguments.last, holding: "new")
            return Shell.Result(status: 0, out: "", err: "")
        })
        XCTAssertFalse(disk.exists, "an unfinished image counted as a vault")

        try await disk.create(password: "fresh-pass")

        XCTAssertTrue(disk.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "another copy may still be creating this one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCreatingNeverTouchesAVaultThatIsAlreadyThere() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("already-there"))
        try Self.writeImage(at: location.image.path, holding: "someone's vault")
        let ran = Locked(false)
        let disk = VaultDisk(location: location, tool: VaultTool { path, _, _, _ in
            ran.set(true)
            throw Shell.ShellError.launchFailed(path)
        })

        do {
            try await disk.create(password: "new-pass")
            XCTFail("A second vault was created over the first")
        } catch {
            XCTAssertEqual(error as? VaultError, .alreadyExists)
        }

        XCTAssertFalse(ran.value)
        XCTAssertEqual(try String(contentsOf: location.image.appendingPathComponent("band"), encoding: .utf8), "someone's vault")
    }

    private static func writeImage(at path: String?, holding text: String) throws {
        let image = URL(fileURLWithPath: try XCTUnwrap(path), isDirectory: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: image.appendingPathComponent("band"))
    }

    private func unfinishedImages(in location: VaultLocation) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: location.folder.path)) ?? []).filter { $0.hasPrefix(VaultDisk.unfinishedPrefix) }
    }

    private struct StandIn {
        let tool: VaultTool
        let timeouts: Locked<[Shell.Timeout]>
        let waitUntilRunning: @MainActor () async throws -> Int32
    }

    private func standIn(for verb: String, script: String, finishing: String?) throws -> StandIn {
        let pidFile = dir.appendingPathComponent("\(verb).pid")
        let timeouts = Locked<[Shell.Timeout]>([])
        let child = Locked<Int32?>(nil)
        killAfterTest(child)
        let tool = VaultTool { _, arguments, input, timeout in
            guard arguments.contains(verb) else { throw Shell.ShellError.launchFailed(verb) }
            timeouts.update { $0.append(timeout) }
            return try await VaultTool.system.run("/bin/sh", ["-c", script, "sh", pidFile.path, finishing ?? arguments.last ?? ""], input, timeout)
        }
        return StandIn(tool: tool, timeouts: timeouts) {
            try await waitUntil("the stand-in for diskutil \(verb) is running") {
                child.set((try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
                return child.value != nil
            }
            return try XCTUnwrap(child.value)
        }
    }

    private func makeOpenDisk(_ name: String) async throws -> VaultDisk {
        let disk = VaultDisk(location: VaultLocation(folder: dir.appendingPathComponent(name)))
        try await disk.create(password: Self.password)
        addTeardownBlock { disk.lockAndWait() }
        try await disk.unlock(password: Self.password)
        XCTAssertTrue(disk.isOpen)
        XCTAssertTrue(disk.location.mountPoint.path.hasPrefix(dir.path + "/"))
        return disk
    }
}
