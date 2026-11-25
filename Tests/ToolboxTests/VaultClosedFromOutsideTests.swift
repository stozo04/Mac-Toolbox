import ImageIO
import VaultSearch
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

@MainActor
final class VaultClosedFromOutsideTests: XCTestCase {
    private static let password = "outside-pass"
    private var dir: URL!

    override func setUp() async throws {
        dir = try makeVaultTestFolder("outside")
    }

    func testAVaultDetachedFromOutsideIsShownAsLockedWithoutAnEject() async throws {
        let (model, steps) = try await makeOpenVault("noticed")
        try await detachFromOutside(model)
        steps.set([])

        XCTAssertTrue(model.lockIfClosedFromOutside())

        XCTAssertEqual(model.phase, .locked)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.thumbnails)
        XCTAssertEqual(model.message, "The vault was closed from outside Toolbox. Unlock to continue.")
        XCTAssertEqual(steps.value, [], "a disk tool was run although nothing was mounted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.disk.location.mountPoint.path))
        XCTAssertFalse(model.lockIfClosedFromOutside(), "the notice was given twice")

        await model.unlock(password: Self.password)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.disk.isOpen)
    }

    func testAVaultThatIsStillMountedIsLeftOpen() async throws {
        let (model, _) = try await makeOpenVault("still-open")

        XCTAssertFalse(model.lockIfClosedFromOutside())
        model.volumeDidUnmount(model.root)

        XCTAssertEqual(model.phase, .open)
        XCTAssertNil(model.message)
    }

    func testOnlyTheVaultsOwnVolumeCountsWhenAVolumeUnmounts() async throws {
        let (model, steps) = try await makeOpenVault("other-volume")
        try await detachFromOutside(model)
        steps.set([])

        model.volumeDidUnmount(URL(fileURLWithPath: "/Volumes/Some Other Disk"))
        model.volumeDidUnmount(nil)
        XCTAssertEqual(model.phase, .open)

        model.volumeDidUnmount(model.root)
        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(model.message, VaultNotices.closedFromOutside(duringImport: false, unconfirmed: 0))
        XCTAssertEqual(steps.value, [])
    }

    func testAnImportStartedAfterTheVaultWasDetachedMovesNothingAndSaysSo() async throws {
        let (model, steps) = try await makeOpenVault("import")
        let first = try makeFile("first.png")
        let second = try makeFile("second.png")
        try await detachFromOutside(model)
        steps.set([])

        model.add([first, second])

        XCTAssertEqual(model.phase, .locked)
        XCTAssertNil(model.moveProgress)
        XCTAssertEqual(model.moveFailures.map(\.name), ["first.png", "second.png"])
        XCTAssertEqual(Set(model.moveFailures.map(\.reason)), ["The vault closed before it was safely inside, so the original was kept."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(model.message, VaultNotices.closedFromOutside(duringImport: true, unconfirmed: 0))
        XCTAssertEqual(steps.value, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.disk.location.mountPoint.path), "a file was left in the plain mount-point folder")
    }

    func testAnImportCutOffByAnOutsideDetachKeepsTheRestAndLocks() async throws {
        let (model, _) = try await makeOpenVault("cut-off")
        let files = try (1...6).map { try makeFile("photo-\($0).png") }
        let mountPoint = model.root.path
        model.moveFile = { file, root in
            if file.lastPathComponent == "photo-3.png" { try await Self.detach(mountPoint) }
            return try await VaultMover.move(file, into: root)
        }

        model.add(files)
        try await waitUntil(timeout: .seconds(60), "the import noticed the vault was gone") { model.phase == .locked }

        XCTAssertEqual(model.moveFailures.map(\.name), ["photo-3.png", "photo-4.png", "photo-5.png", "photo-6.png"])
        XCTAssertEqual(Set(model.moveFailures.map(\.reason)), ["The vault closed before it was safely inside, so the original was kept."])
        XCTAssertEqual(files.map { FileManager.default.fileExists(atPath: $0.path) }, [false, false, true, true, true, true])
        XCTAssertEqual(model.message, VaultNotices.closedFromOutside(duringImport: true, unconfirmed: 0))
        XCTAssertNil(model.moveProgress)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountPoint), "a file was left in the plain mount-point folder")
        if case .failed = model.searchState { XCTFail("a missing vault was shown as a search problem") }
    }

    func testAnOutsideDetachNoticedMidBatchStillListsEveryFileNotMoved() async throws {
        let (model, _) = try await makeOpenVault("noticed-mid-batch")
        let files = try (1...6).map { try makeFile("photo-\($0).png") }
        let mountPoint = model.root.path
        model.moveFile = { [weak model] file, root in
            if file.lastPathComponent == "photo-3.png" {
                try await Self.detach(mountPoint)
                await model?.volumeDidUnmount(root)
            }
            return try await VaultMover.move(file, into: root)
        }

        model.add(files)
        try await waitUntil(timeout: .seconds(60), "the batch has ended") { model.phase == .locked && model.moveProgress == nil }
        try await pause(for: .milliseconds(300), because: "a late report from the cancelled batch would arrive by now")

        XCTAssertEqual(model.moveFailures.map(\.name), ["photo-3.png", "photo-4.png", "photo-5.png", "photo-6.png"])
        XCTAssertEqual(files.map { FileManager.default.fileExists(atPath: $0.path) }, [false, false, true, true, true, true])
        XCTAssertEqual(model.message, VaultNotices.closedFromOutside(duringImport: true, unconfirmed: 0))
    }

    func testAFileThatFinishedMovingAsTheVaultClosedIsNeverReportedAsKept() async throws {
        let (model, _) = try await makeOpenVault("finished-as-closed")
        let files = try (1...6).map { try makeFile("photo-\($0).png") }
        let mountPoint = model.root.path
        model.moveFile = { [weak model] file, root in
            let moved = try await VaultMover.move(file, into: root)
            if file.lastPathComponent == "photo-3.png" {
                try await Self.detach(mountPoint)
                await model?.volumeDidUnmount(root)
            }
            return moved
        }

        model.add(files)
        try await waitUntil(timeout: .seconds(60), "the batch has ended") { model.phase == .locked && model.moveProgress == nil }
        try await pause(for: .milliseconds(300), because: "a late report from the cancelled batch would arrive by now")

        XCTAssertEqual(files.map { FileManager.default.fileExists(atPath: $0.path) }, [false, false, false, true, true, true])
        XCTAssertEqual(model.moveFailures.map(\.name), ["photo-3.png", "photo-4.png", "photo-5.png", "photo-6.png"])
        XCTAssertEqual(model.moveFailures.map(\.reason), [
            "It finished moving just as the vault closed. Check it after you unlock.",
            "The vault closed before it was safely inside, so the original was kept.",
            "The vault closed before it was safely inside, so the original was kept.",
            "The vault closed before it was safely inside, so the original was kept.",
        ])
        XCTAssertEqual(model.message, "The vault was closed from outside Toolbox. Files that had not been moved yet are still where they were. "
            + "1 file finished moving just as the vault closed; check it after you unlock. Unlock to continue.")
    }

    func testAMoveThatFinishesAfterTheNoticeCorrectsTheReport() async throws {
        let (model, _) = try await makeOpenVault("finished-after-notice")
        let files = try (1...4).map { try makeFile("photo-\($0).png") }
        let mountPoint = model.root.path
        model.moveFile = { [weak model] file, root in
            guard file.lastPathComponent == "photo-2.png" else { return try await VaultMover.move(file, into: root) }
            try await Self.detach(mountPoint)
            await model?.volumeDidUnmount(root)
            try FileManager.default.removeItem(at: file)
            return root.appendingPathComponent(file.lastPathComponent)
        }

        model.add(files)
        try await waitUntil(timeout: .seconds(60), "the late move was reported") {
            model.moveFailures.contains { $0.reason == VaultNotices.finishedAsVaultClosed }
        }

        XCTAssertEqual(model.moveFailures.map(\.name), ["photo-2.png", "photo-3.png", "photo-4.png"])
        XCTAssertEqual(model.moveFailures.map(\.reason), [
            VaultNotices.finishedAsVaultClosed,
            "The vault closed before it was safely inside, so the original was kept.",
            "The vault closed before it was safely inside, so the original was kept.",
        ])
        XCTAssertEqual(files.map { FileManager.default.fileExists(atPath: $0.path) }, [false, false, true, true])
        XCTAssertEqual(model.message, VaultNotices.closedFromOutside(duringImport: true, unconfirmed: 1))
        XCTAssertEqual(model.phase, .locked)
    }

    func testASearchIndexThatFailsBecauseTheVaultIsGoneLocksInsteadOfBlamingSearch() async throws {
        guard EmbeddingModel.locate() != nil else { throw XCTSkip("needs the search model on this Mac") }
        let (model, steps) = try await makeOpenVault("index")
        try await detachFromOutside(model)
        steps.set([])

        model.retrySearch()
        try await waitUntil(timeout: .seconds(60), "the index noticed the vault was gone") { model.phase == .locked }

        XCTAssertEqual(model.message, VaultNotices.closedFromOutside(duringImport: false, unconfirmed: 0))
        if case .failed = model.searchState { XCTFail("a missing vault was shown as a search problem") }
        XCTAssertEqual(steps.value, [])
    }

    private func makeOpenVault(_ name: String) async throws -> (VaultModel, Locked<[String]>) {
        let steps = Locked<[String]>([])
        let recording = VaultTool { path, arguments, input, timeout in
            steps.update { $0.append(arguments.first ?? path) }
            return try await VaultTool.system.run(path, arguments, input, timeout)
        }
        let location = VaultLocation(folder: dir.appendingPathComponent(name))
        let model = VaultModel(location: location, watchesSystem: false, tool: recording, anotherCopyIsRunning: { false })
        addTeardownBlock { @MainActor in await model.lock() }
        await model.create(password: Self.password, confirmation: Self.password)
        model.finishOpening()
        XCTAssertEqual(model.phase, .open, model.message ?? "")
        XCTAssertTrue(model.root.path.hasPrefix(dir.path + "/"))
        return (model, steps)
    }

    private func detachFromOutside(_ model: VaultModel) async throws {
        try await Self.detach(model.root.path)
        XCTAssertFalse(model.disk.isOpen)
    }

    private nonisolated static func detach(_ mountPoint: String) async throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard URL(fileURLWithPath: mountPoint).resolvingSymlinksInPath().path.hasPrefix(temporary + "/vault-outside-") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let detach = try await Shell.run(VaultDisk.hdiutil, ["detach", "-force", mountPoint], timeout: .seconds(60))
        guard detach.succeeded else { throw VaultError.diskTool(action: "be detached by the test", message: detach.err) }
    }

    private func makeFile(_ name: String) throws -> URL {
        let folder = dir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try VaultTestMedia.uniquePhoto(at: folder.appendingPathComponent(name))
    }
}
