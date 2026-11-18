import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class VaultTests: XCTestCase {
    private func makeScratchFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testTheCopyIsMadeAsANewFileAndNeverOverAnExistingOne() throws {
        let folder = try makeScratchFolder("vault-exclusive")
        let taken = folder.appendingPathComponent("photo.png")
        try Data("theirs".utf8).write(to: taken)

        let source = folder.appendingPathComponent("source.png")
        try Data("ours".utf8).write(to: source)

        XCTAssertThrowsError(try VaultMover.copyAsNewFile(source, to: taken)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(try Data(contentsOf: taken), Data("theirs".utf8))
    }

    func testTheCopyKeepsTheIdentityOfTheFileThisMoveMade() throws {
        let folder = try makeScratchFolder("vault-identity")
        let source = folder.appendingPathComponent("source.png"), copy = folder.appendingPathComponent("copy.png")
        try Data("picture".utf8).write(to: source)

        let made = try VaultMover.copyAsNewFile(source, to: copy)

        XCTAssertEqual(VaultMover.fileIdentity(of: copy), made)
        XCTAssertEqual(try Data(contentsOf: copy), Data("picture".utf8))
    }

    func testAnotherFileThatTookThePathIsNotTheFileThisMoveMade() throws {
        let folder = try makeScratchFolder("vault-replaced")
        let path = folder.appendingPathComponent("photo.png"), other = folder.appendingPathComponent("other.png")
        let source = folder.appendingPathComponent("source.png")
        try Data("ours".utf8).write(to: source)
        let made = try VaultMover.copyAsNewFile(source, to: path)
        try Data("theirs".utf8).write(to: other)

        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: other, to: path)
        VaultMover.removeIfStill(made, at: path)

        XCTAssertEqual(try Data(contentsOf: path), Data("theirs".utf8), "a file this move did not make is left alone")
    }

    func testAMoveThatFailsRemovesItsCopyEvenWhenTheOriginalIsOld() async throws {
        let folder = try makeScratchFolder("vault-old-original")
        let vault = folder.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let source = try makePhoto("old.png", in: folder)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: source.path)
        struct CannotSave: Error {}

        do {
            _ = try await VaultMover.move(source, into: vault, requiresMountedVolume: false, flush: { _ in throw CannotSave() })
            XCTFail("the move should have failed")
        } catch is CannotSave {}

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path), [], "an unfinished copy is never left behind")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private var dir: URL!
    private var source: URL!
    private var vault: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID())")
        source = dir.appendingPathComponent("source")
        vault = dir.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testKindComesFromTheFileType() {
        XCTAssertEqual(VaultItem.kind(of: URL(fileURLWithPath: "/a/b.JPG")), .image)
        XCTAssertEqual(VaultItem.kind(of: URL(fileURLWithPath: "/a/b.heic")), .image)
        XCTAssertEqual(VaultItem.kind(of: URL(fileURLWithPath: "/a/b.mov")), .video)
        XCTAssertEqual(VaultItem.kind(of: URL(fileURLWithPath: "/a/b.mp4")), .video)
        XCTAssertNil(VaultItem.kind(of: URL(fileURLWithPath: "/a/b.mp3")))
        XCTAssertNil(VaultItem.kind(of: URL(fileURLWithPath: "/a/b.pdf")))
        XCTAssertNil(VaultItem.kind(of: URL(fileURLWithPath: "/a/b")))
    }

    func testMoveDeletesTheOriginalOnlyAfterAnExactCopyExists() async throws {
        let photo = try makePhoto("beach.png")
        let original = try Data(contentsOf: photo)

        let moved = try await VaultMover.move(photo, into: vault, requiresMountedVolume: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertEqual(moved.lastPathComponent, "beach.png")
        XCTAssertEqual(try Data(contentsOf: moved), original)
    }

    func testMoveKeepsBothFilesWhenTheNameIsTaken() async throws {
        _ = try await VaultMover.move(try makePhoto("cat.png"), into: vault, requiresMountedVolume: false)
        let second = try await VaultMover.move(try makePhoto("cat.png"), into: vault, requiresMountedVolume: false)
        XCTAssertEqual(second.lastPathComponent, "cat 2.png")
        XCTAssertEqual(VaultLibrary.items(in: vault).count, 2)
    }

    func testUnsupportedFilesStayWhereTheyAre() async throws {
        let note = source.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        await assertMoveFails(note, with: .unsupportedType)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(VaultLibrary.items(in: vault).isEmpty)
    }

    func testPhotosLibraryFilesAreRefused() async throws {
        let library = source.appendingPathComponent("Photos Library.photoslibrary/originals")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let photo = try makePhoto("inside.png", in: library)
        await assertMoveFails(photo, with: .insidePhotosLibrary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
    }

    func testFilesAlreadyInTheVaultAreRefused() async throws {
        let inside = try makePhoto("inside.png", in: vault)
        await assertMoveFails(inside, with: .alreadyInVault)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    func testLinksAreRefusedSoTheRealFileIsNeverLeftOutside() async throws {
        let real = try makePhoto("real.png", in: dir)
        let symbolic = source.appendingPathComponent("shortcut.png")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: real)
        await assertMoveFails(symbolic, with: .link)

        let hard = source.appendingPathComponent("second-name.png")
        try FileManager.default.linkItem(at: real, to: hard)
        await assertMoveFails(hard, with: .link)

        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hard.path))
        XCTAssertTrue(VaultLibrary.items(in: vault).isEmpty)
    }

    func testAFolderLinkIntoAPhotosLibraryIsStillRefused() async throws {
        let originals = dir.appendingPathComponent("Photos Library.photoslibrary/originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let photo = try makePhoto("managed.png", in: originals)
        let shortcut = source.appendingPathComponent("Shortcut")
        try FileManager.default.createSymbolicLink(at: shortcut, withDestinationURL: originals)
        await assertMoveFails(shortcut.appendingPathComponent("managed.png"), with: .insidePhotosLibrary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
    }

    func testAMoveStoppedByLockingKeepsTheOriginal() async throws {
        let photo = try makePhoto("kept.png")
        let vault = try XCTUnwrap(vault)
        let stopped = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VaultMover.move(photo, into: vault, requiresMountedVolume: false)
        }
        do {
            _ = try await stopped.value
            XCTFail("A cancelled move deleted the original")
        } catch {
            XCTAssertEqual(error as? VaultMoveError, .interrupted)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertTrue(VaultLibrary.items(in: vault).isEmpty)
    }

    func testAHiddenPhotoGetsAVisibleNameInTheVault() async throws {
        let hidden = try makePhoto(".private.png")
        let moved = try await VaultMover.move(hidden, into: vault, requiresMountedVolume: false)
        XCTAssertEqual(moved.lastPathComponent, "private.png")
        XCTAssertEqual(VaultLibrary.items(in: vault).map(\.name), ["private.png"])
    }

    func testFingerprintNoticesAnEditedOriginal() throws {
        let photo = try makePhoto("edited.png")
        let before = try VaultMover.fingerprint(photo)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: photo.path)
        XCTAssertNotEqual(try VaultMover.fingerprint(photo), before)
    }

    func testOriginalIsKeptWhenTheCopyVanishesBeforeDeleting() throws {
        let photo = try makePhoto("present.png")
        XCTAssertFalse(VaultMover.copyIsStillThere(vault.appendingPathComponent("present.png"), matching: photo))
        let copy = vault.appendingPathComponent("present.png")
        try FileManager.default.copyItem(at: photo, to: copy)
        XCTAssertTrue(VaultMover.copyIsStillThere(copy, matching: photo))
    }

    func testTruncatedPhotoIsRefusedAndKept() async throws {
        let whole = try Data(contentsOf: try makePhoto("whole.png"))
        let truncated = source.appendingPathComponent("truncated.png")
        try whole.prefix(whole.count / 2).write(to: truncated)
        await assertMoveFails(truncated, with: .unreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: truncated.path))
        XCTAssertTrue(VaultLibrary.items(in: vault).isEmpty)
    }

    func testAMoveIntoAVaultThatWasDetachedKeepsTheOriginal() async throws {
        let disk = try await makeOpenDisk("detached")
        try await detachFromOutside(disk)
        let photo = try makePhoto("secret.png")

        do {
            _ = try await VaultMover.move(photo, into: disk.location.mountPoint)
            XCTFail("The move went into a plain folder on the startup disk")
        } catch {
            XCTAssertEqual(error as? VaultMoveError, .vaultNotOpen)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: disk.location.mountPoint.path)) ?? [], [])
    }

    func testAVaultDetachedWhileAFileMovesInKeepsTheOriginal() async throws {
        let disk = try await makeOpenDisk("detached-midway")
        let photo = try makePhoto("secret.png")

        do {
            _ = try await VaultMover.move(photo, into: disk.location.mountPoint) { copy in
                try VaultMover.flushToDisk(copy)
                disk.lockAndWait()
            }
            XCTFail("The original was deleted although the vault had closed")
        } catch {
            XCTAssertEqual(error as? VaultMoveError, .vaultNotOpen)
        }

        XCTAssertFalse(disk.isOpen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.location.mountPoint.path), "something was left in the mount point folder")
    }

    func testACopyThatCannotBeSavedToDiskKeepsTheOriginal() async throws {
        let photo = try makePhoto("unsaved.png")
        let vault = try XCTUnwrap(vault)

        do {
            _ = try await VaultMover.move(photo, into: vault, requiresMountedVolume: false) { _ in throw VaultMoveError.notSaved("disk error") }
            XCTFail("The original was deleted although its copy was never saved to the disk")
        } catch {
            XCTAssertEqual(error as? VaultMoveError, .notSaved("disk error"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertTrue(VaultLibrary.items(in: vault).isEmpty)
    }

    func testAMovedFileIsFlushedBeforeTheOriginalIsDeleted() async throws {
        let photo = try makePhoto("flushed.png")
        let vault = try XCTUnwrap(vault)
        let originalExistedAtFlush = Flag()

        _ = try await VaultMover.move(photo, into: vault, requiresMountedVolume: false) { copy in
            if FileManager.default.fileExists(atPath: photo.path) { originalExistedAtFlush.set() }
            try VaultMover.flushToDisk(copy)
        }

        XCTAssertTrue(originalExistedAtFlush.isSet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertThrowsError(try VaultMover.flushToDisk(vault.appendingPathComponent("missing.png")))
    }

    func testACopyThatRunsOutOfSpaceLeavesNothingBehind() async throws {
        let tiny = try await attachTinyVolume()
        let big = source.appendingPathComponent("big.png")
        try Data((0..<24 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }).write(to: big)
        let before = try FileManager.default.contentsOfDirectory(atPath: tiny.path).sorted()

        do {
            _ = try await VaultMover.move(big, into: tiny)
            XCTFail("A 24 MB file fitted on a 2 MB volume")
        } catch {
            XCTAssertNil(error as? VaultMoveError, "the copy itself should have failed: \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tiny.path).sorted(), before, "the failed copy left files behind")
    }

    @MainActor
    func testLockingWhileTheDoorIsUnlockingKeepsTheVaultClosed() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("race"))
        try await VaultDisk(location: location).create(password: "race-pass")
        let model = VaultModel(location: location, watchesSystem: false)
        XCTAssertEqual(model.phase, .locked)

        defer { model.lockImmediately() }
        let unlocking = Task { await model.unlock(password: "race-pass") }
        try await waitUntil("the unlock is under way") { model.isWorking }
        model.lockImmediately()
        await unlocking.value

        XCTAssertFalse(model.disk.isOpen)
        XCTAssertEqual(model.phase, .locked)
    }

    @MainActor
    func testMovingManyFilesInReadsTheWholeLibraryOnce() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("batch"))
        let model = VaultModel(location: location, watchesSystem: false)
        await model.create(password: "batch-pass", confirmation: "batch-pass")
        model.finishOpening()
        defer { model.lockImmediately() }
        let files = try (0..<12).map { try makePhoto("new-\($0).png") }
        let reloadsBefore = model.libraryReloads

        model.add(files)
        try await waitUntil(timeout: .seconds(60), "the files are in the vault") { model.moveProgress == nil }

        XCTAssertTrue(model.moveFailures.isEmpty)
        XCTAssertEqual(model.items, VaultLibrary.items(in: model.root))
        XCTAssertEqual(model.items.count, files.count)
        XCTAssertEqual(model.libraryReloads - reloadsBefore, 1, "moving \(files.count) files in read the whole library once per file")
    }

    func testAnItemAddedToTheListMatchesWhatReadingTheLibraryFinds() async throws {
        let vault = try XCTUnwrap(vault)
        _ = try makePhoto("older.png", in: vault)
        let before = VaultLibrary.items(in: vault)
        let moved = try await VaultMover.move(try makePhoto("newer.png"), into: vault, requiresMountedVolume: false)

        let added = try XCTUnwrap(VaultLibrary.item(movedTo: moved))

        XCTAssertEqual(VaultLibrary.inserting(added, into: before), VaultLibrary.items(in: vault))
        XCTAssertNil(VaultLibrary.item(movedTo: vault.appendingPathComponent("missing.png")))
    }

    @MainActor
    func testDuplicatesNotKeptGoToTheVaultTrashAndComeBack() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("trash"))
        let model = VaultModel(location: location, watchesSystem: false)
        await model.create(password: "trash-pass", confirmation: "trash-pass")
        model.finishOpening()
        defer { model.lockImmediately() }
        let photo = try makePhoto("a.png")
        let twin = source.appendingPathComponent("b.png")
        try FileManager.default.copyItem(at: photo, to: twin)

        model.add([photo, twin])
        try await waitUntil(timeout: .seconds(30), "both files are in the vault") { model.moveProgress == nil && model.items.count == 2 }
        model.mode = .duplicates
        try await waitUntil(timeout: .seconds(30), "duplicates have been looked for") { model.duplicateGroups != nil }
        let group = try XCTUnwrap(model.visibleDuplicateGroups?.first)
        let keeper = try XCTUnwrap(group.copies.first)

        await model.keep(keeper, in: group)

        XCTAssertEqual(model.items.map(\.name), [keeper.name])
        XCTAssertEqual(model.trash.count, 1)
        let privateFolder = model.root.appendingPathComponent(VaultLibrary.privateFolderName)
        XCTAssertTrue(VaultTrash.contents(in: privateFolder).allSatisfy { $0.path.hasPrefix(model.root.path + "/") },
                      "Trashed copies stay inside the encrypted image")

        model.putBackTrash()
        XCTAssertEqual(model.items.count, 2)
        XCTAssertTrue(model.trash.isEmpty)

        try await waitUntil(timeout: .seconds(30), "the group has two copies again") { model.duplicateGroups?.first?.copies.count == 2 }
        let again = try XCTUnwrap(model.visibleDuplicateGroups?.first)
        await model.keep(try XCTUnwrap(again.copies.first), in: again)
        model.emptyTrash()
        XCTAssertTrue(model.trash.isEmpty)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertTrue(VaultTrash.contents(in: privateFolder).isEmpty)
    }

    @MainActor
    func testRenamingKeepsTheViewerDetailsAndSelectionOnTheFile() async throws {
        let location = VaultLocation(folder: dir.appendingPathComponent("rename"))
        let model = VaultModel(location: location, watchesSystem: false)
        await model.create(password: "rename-pass", confirmation: "rename-pass")
        model.finishOpening()
        defer { model.lockImmediately() }
        model.add([try makePhoto("a.png")])
        try await waitUntil(timeout: .seconds(30), "the file is in the vault") { model.moveProgress == nil && model.items.count == 1 }
        let photo = try XCTUnwrap(model.items.first)
        model.viewing = photo.id
        model.detailing = photo.id
        model.selection = [photo.id]

        let renamed = try await model.rename(photo, to: "beach")

        XCTAssertEqual(model.items.map(\.name), ["beach.png"])
        XCTAssertEqual(renamed.name, "beach.png")
        XCTAssertEqual(model.viewing, renamed.id)
        XCTAssertEqual(model.detailing, renamed.id)
        XCTAssertEqual(model.selection, [renamed.id])
        XCTAssertFalse(model.searchFailures.contains(renamed.id))
        do {
            _ = try await model.rename(renamed, to: "  ")
            XCTFail("An empty name is refused")
        } catch {
            XCTAssertEqual(error as? VaultRenameError, .empty)
        }
    }

    func testVerifyCatchesACopyThatDiffers() async throws {
        let first = try makePhoto("a.png", red: 255)
        let second = try makePhoto("b.png", red: 10)
        do {
            try await VaultMover.verify(copy: second, of: first)
            XCTFail("Different files passed verification")
        } catch {
            XCTAssertEqual(error as? VaultMoveError, .copyDiffers)
        }
        try await VaultMover.verify(copy: first, of: first)
    }

    func testVerifyCatchesACopyThatWontOpen() async throws {
        let broken = source.appendingPathComponent("broken.jpg")
        try Data("not a picture".utf8).write(to: broken)
        do {
            try await VaultMover.verify(copy: broken, of: broken)
            XCTFail("An unreadable file passed verification")
        } catch {
            XCTAssertEqual(error as? VaultMoveError, .unreadable)
        }
    }

    func testFoldersExpandToTheirPhotosAndVideos() throws {
        let album = source.appendingPathComponent("Album/Day 1")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        _ = try makePhoto("one.png", in: album)
        _ = try makePhoto("two.png", in: album.deletingLastPathComponent())
        try Data("x".utf8).write(to: album.appendingPathComponent("notes.txt"))
        let names = VaultMover.expand([source.appendingPathComponent("Album")]).map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["one.png", "two.png"])
    }

    func testLibraryHidesToolboxFilesAndNonMedia() throws {
        _ = try makePhoto("shown.png", in: vault)
        let thumbs = vault.appendingPathComponent(".toolbox/thumbs")
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        _ = try makePhoto("thumb.png", in: thumbs)
        try Data().write(to: vault.appendingPathComponent(VaultDisk.spotlightOptOut))
        try Data("x".utf8).write(to: vault.appendingPathComponent("readme.txt"))
        XCTAssertEqual(VaultLibrary.items(in: vault).map(\.name), ["shown.png"])
    }

    func testViewerStepsThroughItemsAndStopsAtTheEnds() {
        let items = ["a", "b", "c"].map {
            VaultItem(url: URL(fileURLWithPath: "/v/\($0).png"), kind: .image, added: Date(), bytes: 1)
        }
        XCTAssertEqual(VaultLibrary.neighbor(of: try items.element(at: 1).id, in: items, step: 1), try items.element(at: 2).id)
        XCTAssertEqual(VaultLibrary.neighbor(of: try items.element(at: 1).id, in: items, step: -1), try XCTUnwrap(items.first).id)
        XCTAssertNil(VaultLibrary.neighbor(of: try items.element(at: 2).id, in: items, step: 1))
        XCTAssertNil(VaultLibrary.neighbor(of: try XCTUnwrap(items.first).id, in: items, step: -1))
        XCTAssertNil(VaultLibrary.neighbor(of: "/missing", in: items, step: 1))
    }

    func testLockingAVaultThatIsStillAttachingLeavesItsMountPointAlone() async throws {
        let disk = VaultDisk(location: VaultLocation(folder: dir.appendingPathComponent("attaching")))
        try FileManager.default.createDirectory(at: disk.location.mountPoint, withIntermediateDirectories: true)
        try await disk.lock()
        disk.lockAndWait()
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.location.mountPoint.path))
    }

    func testAClosedGateDropsLateThumbnailWrites() {
        let gate = VaultWriteGate()
        var writes = 0
        gate.write { writes += 1 }
        gate.close()
        gate.write { writes += 1 }
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(gate.isClosed)
    }

    func testThumbnailsAreNotWrittenWhenTheVaultIsNotMounted() async throws {
        let photo = try makePhoto("unmounted.png", in: vault)
        let item = try XCTUnwrap(VaultLibrary.items(in: vault).first { $0.url.lastPathComponent == photo.lastPathComponent })
        let thumbnails = VaultThumbnails(vaultRoot: vault)
        let image = await thumbnails.image(for: item)
        XCTAssertNil(image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent(".toolbox").path))
    }

    func testThumbnailMemoryDropsTheLeastRecentlyShownPastItsLimit() async throws {
        let photos = try (0..<8).map { try makePhoto("tile-\($0).png", in: vault) }
        let items = VaultLibrary.items(in: vault)
        XCTAssertEqual(items.count, photos.count)
        let probe = VaultThumbnails(vaultRoot: vault, requiresMountedVolume: false)
        let probed = await probe.image(for: try XCTUnwrap(items.first))
        let oneThumbnail = VaultThumbnailMemory.bytes(of: try XCTUnwrap(probed))
        let thumbnails = VaultThumbnails(vaultRoot: vault, requiresMountedVolume: false, memoryByteLimit: oneThumbnail * 3)

        var shown: [CGImage] = []
        for item in items {
            let image = await thumbnails.image(for: item)
            shown.append(try XCTUnwrap(image))
        }

        let held = await thumbnails.memoryCount
        let heldBytes = await thumbnails.memoryBytes
        XCTAssertEqual(held, 3, "\(items.count) thumbnails were shown and \(held) are still in memory")
        XCTAssertEqual(heldBytes, oneThumbnail * 3)
        let newestAgain = await thumbnails.image(for: try XCTUnwrap(items.last))
        XCTAssertTrue(newestAgain === shown.last, "the thumbnail shown last was dropped")
    }

    func testThumbnailMemoryKeepsWhatWasJustLookedAt() throws {
        let image = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let cost = VaultThumbnailMemory.bytes(of: image)
        var memory = VaultThumbnailMemory(byteLimit: cost * 2)
        memory.keep(image, for: "first")
        memory.keep(image, for: "second")
        XCTAssertNotNil(memory.image(for: "first"))

        memory.keep(image, for: "third")

        XCTAssertNotNil(memory.image(for: "first"))
        XCTAssertNil(memory.image(for: "second"))
        XCTAssertNotNil(memory.remove("third"))
        XCTAssertEqual(memory.bytes, cost)
        memory.removeAll()
        XCTAssertEqual(memory.bytes, 0)
        XCTAssertEqual(memory.count, 0)
    }

    func testAThumbnailRequestCancelledBeforeItStartsDecodesNothing() async throws {
        _ = try makePhoto("scrolled-past.png", in: vault)
        let item = try XCTUnwrap(VaultLibrary.items(in: vault).first)
        let thumbnails = VaultThumbnails(vaultRoot: vault, requiresMountedVolume: false)

        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await thumbnails.image(for: item)
        }
        let image = await request.value

        let held = await thumbnails.memoryCount
        let folder = await thumbnails.folder
        XCTAssertNil(image)
        XCTAssertEqual(held, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a cancelled request still wrote a thumbnail")
    }

    func testNewestItemsComeFirst() {
        let old = VaultItem(url: URL(fileURLWithPath: "/v/old.png"), kind: .image, added: Date(timeIntervalSince1970: 1), bytes: 1)
        let new = VaultItem(url: URL(fileURLWithPath: "/v/new.png"), kind: .image, added: Date(timeIntervalSince1970: 2), bytes: 1)
        XCTAssertEqual(VaultLibrary.sorted([old, new]).map(\.name), ["new.png", "old.png"])
    }

    func testNewPasswordRules() {
        XCTAssertThrowsError(try VaultDisk.validateNewPassword("short", confirmation: "short")) {
            XCTAssertEqual($0 as? VaultError, .passwordTooShort)
        }
        XCTAssertThrowsError(try VaultDisk.validateNewPassword("long enough", confirmation: "different")) {
            XCTAssertEqual($0 as? VaultError, .passwordsDiffer)
        }
        XCTAssertNoThrow(try VaultDisk.validateNewPassword("long enough", confirmation: "long enough"))
    }

    func testLogsNeverCarryTheFileName() {
        let file = URL(fileURLWithPath: "/Users/someone/Private/holiday-photo.jpg")
        let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: "“holiday-photo.jpg” couldn't be moved."])
        let metadata = VaultLog.details(error, file: file)
        XCTAssertFalse(metadata.values.contains { $0.contains("holiday-photo") })
        XCTAssertEqual(metadata["file_ext"], "jpg")
        XCTAssertNil(metadata["file_name"])
    }

    func testEncryptedVaultOpensOnlyWithItsPassword() async throws {
        let disk = VaultDisk(location: VaultLocation(folder: dir.appendingPathComponent("disk")))
        XCTAssertFalse(disk.exists)

        try await disk.create(password: "first-pass")
        XCTAssertTrue(disk.exists)
        XCTAssertFalse(disk.isOpen)

        do {
            try await disk.unlock(password: "wrong-pass")
            XCTFail("A wrong password opened the vault")
        } catch {
            XCTAssertEqual(error as? VaultError, .wrongPassword)
        }

        try await disk.unlock(password: "first-pass")
        XCTAssertTrue(disk.isOpen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.location.mountPoint.appendingPathComponent(VaultDisk.spotlightOptOut).path))
        _ = try await VaultMover.move(try makePhoto("secret.png"), into: disk.location.mountPoint)
        try await disk.lock()
        XCTAssertFalse(disk.isOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.location.mountPoint.path), "an empty mount point is left behind")

        try await disk.changePassword(from: "first-pass", to: "second-pass")
        do {
            try await disk.unlock(password: "first-pass")
            XCTFail("The old password still opens the vault")
        } catch {
            XCTAssertEqual(error as? VaultError, .wrongPassword)
        }
        try await disk.unlock(password: "second-pass")
        XCTAssertEqual(VaultLibrary.items(in: disk.location.mountPoint).map(\.name), ["secret.png"])

        do {
            try await disk.unlock(password: "wrong-pass")
            XCTFail("A wrong password was accepted because the vault was already open")
        } catch {
            XCTAssertEqual(error as? VaultError, .wrongPassword)
        }
        XCTAssertFalse(disk.isOpen)
        disk.lockAndWait()
        XCTAssertFalse(disk.isOpen)
    }

    private static let toolTimeout = Shell.Timeout.seconds(60)

    private func makeOpenDisk(_ name: String) async throws -> VaultDisk {
        let disk = VaultDisk(location: VaultLocation(folder: dir.appendingPathComponent(name)))
        try await disk.create(password: "disk-pass")
        addTeardownBlock { disk.lockAndWait() }
        try await disk.unlock(password: "disk-pass")
        XCTAssertTrue(disk.isOpen)
        XCTAssertTrue(disk.location.mountPoint.path.hasPrefix(dir.path + "/"))
        return disk
    }

    private func detachFromOutside(_ disk: VaultDisk) async throws {
        let detach = try await Shell.run(VaultDisk.hdiutil, ["detach", "-force", disk.location.mountPoint.path], timeout: Self.toolTimeout)
        XCTAssertTrue(detach.succeeded, detach.err)
        XCTAssertFalse(disk.isOpen)
    }

    private func attachTinyVolume() async throws -> URL {
        let image = dir.appendingPathComponent("tiny.dmg")
        let mountPoint = dir.appendingPathComponent("tiny")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        let created = try await Shell.run(VaultDisk.hdiutil, ["create", "-size", "2m", "-fs", "APFS", "-volname", "Tiny", image.path],
                                          timeout: Self.toolTimeout)
        XCTAssertTrue(created.succeeded, created.err)
        addTeardownBlock {
            _ = try? await Shell.run(VaultDisk.hdiutil, ["detach", "-force", mountPoint.path], timeout: Self.toolTimeout)
        }
        let attached = try await Shell.run(VaultDisk.hdiutil, ["attach", "-nobrowse", "-mountpoint", mountPoint.path, image.path],
                                           timeout: Self.toolTimeout)
        XCTAssertTrue(attached.succeeded, attached.err)
        return mountPoint
    }

    private func assertMoveFails(_ url: URL, with expected: VaultMoveError, line: UInt = #line) async {
        do {
            _ = try await VaultMover.move(url, into: vault, requiresMountedVolume: false)
            XCTFail("Move should have failed", line: line)
        } catch {
            XCTAssertEqual(error as? VaultMoveError, expected, line: line)
        }
    }

    private func makePhoto(_ name: String, in folder: URL? = nil, red: UInt8 = 200) throws -> URL {
        let url = (folder ?? source).appendingPathComponent(name)
        let width = 8, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = red
            pixels[i + 1] = 80
            pixels[i + 2] = 40
            pixels[i + 3] = 255
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isSet: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
