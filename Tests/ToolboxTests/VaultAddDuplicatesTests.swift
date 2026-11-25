import XCTest
@testable import Toolbox

/// An add that meets copies already in the vault, on a real encrypted vault in a temporary folder.
@MainActor
final class VaultAddDuplicatesTests: XCTestCase {
    private var dir: URL!
    private var source: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-add-duplicates-\(UUID())")
        source = dir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testKeepingTheVaultCopyLeavesTheNewFileExactlyWhereItWas() async throws {
        let model = try await openVault()
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))])
        let twin = try copy(of: "a.png", from: model.root, as: "twin.png")
        let before = try fingerprint(twin)

        let review = try await addAndShowReview(model, [twin])
        review.toggle(try XCTUnwrap(review.group?.copies.first { !$0.isIncoming }).id)
        review.confirm()
        try await waitUntilDone(model)

        XCTAssertEqual(try fingerprint(twin), before, "the new file was touched")
        XCTAssertEqual(model.items.map(\.name), ["a.png"])
        XCTAssertTrue(model.trash.isEmpty)
        XCTAssertEqual(model.notice, "0 added, 0 replaced with a better copy, 1 kept as they were, 0 kept both")
    }

    func testKeepingAllAddsTheFileAndTheSetIsNeverSuggestedAgain() async throws {
        let model = try await openVault()
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))])
        let twin = try copy(of: "a.png", from: model.root, in: "again")

        let review = try await addAndShowReview(model, [twin])
        review.keepAll()
        review.confirm()
        try await waitUntilDone(model)

        XCTAssertEqual(Set(model.items.map(\.name)), ["a.png", "a 2.png"])
        XCTAssertEqual(model.notice, "0 added, 0 replaced with a better copy, 0 kept as they were, 1 kept both")
        model.mode = .duplicates
        try await waitUntil(timeout: .seconds(30), "duplicates have been looked for") { model.duplicateGroups != nil }
        XCTAssertEqual(model.duplicateGroups, [], "a set kept whole was suggested again")
    }

    func testANewFileWithNoMatchGoesInWithoutAsking() async throws {
        let model = try await openVault()
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))])
        let other = try VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("b.png"))

        model.add([other])
        try await waitUntilDone(model)

        XCTAssertNil(model.comparison)
        XCTAssertEqual(Set(model.items.map(\.name)), ["a.png", "b.png"])
        XCTAssertNil(model.notice, "a plain add has no duplicates summary")
    }

    func testKeepingOnlyTheNewFileReplacesEveryVaultCopyWithIt() async throws {
        let model = try await openVault()
        let original = try VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))
        try FileManager.default.copyItem(at: original, to: model.root.appendingPathComponent("a.png"))
        try FileManager.default.copyItem(at: original, to: model.root.appendingPathComponent("a copy.png"))
        model.reload()
        let third = try copy(of: "a.png", from: source, in: "new")

        let review = try await addAndShowReview(model, [third])
        XCTAssertEqual(review.group?.copies.count, 3, "every copy in the vault is shown")
        review.toggle(try XCTUnwrap(review.group?.copies.first(where: \.isIncoming)).id)
        review.confirm()
        try await waitUntilDone(model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: third.path))
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.trash.count, 2)
        XCTAssertEqual(model.notice, "0 added, 1 replaced with a better copy, 0 kept as they were, 0 kept both")
    }

    func testFilesInOneAddThatMatchEachOtherAreComparedTogether() async throws {
        let model = try await openVault()
        let first = try VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))
        let second = try copy(of: "a.png", from: source, as: "b.png")

        let review = try await addAndShowReview(model, [first, second])
        XCTAssertEqual(review.group?.copies.map(\.isIncoming), [true, true])
        review.toggle(try XCTUnwrap(review.group?.copies.first).id)
        review.confirm()
        try await waitUntilDone(model)

        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.notice, "1 added, 0 replaced with a better copy, 1 kept as they were, 0 kept both")
    }

    func testCancellingLeavesEveryFileNotReachedWhereItWasWithoutCallingItAFailure() async throws {
        let model = try await openVault()
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))])
        let twin = try copy(of: "a.png", from: model.root, as: "twin.png")
        let fresh = try VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("fresh.png"))

        let review = try await addAndShowReview(model, [twin, fresh])
        review.cancel()
        try await waitUntilDone(model)

        XCTAssertTrue(FileManager.default.fileExists(atPath: twin.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "the file with no match went in first")
        XCTAssertTrue(model.moveFailures.isEmpty)
    }

    func testAVaultCopyThatChangedBeforeTheChoiceIsLeftAlone() async throws {
        let model = try await openVault()
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))])
        let twin = try copy(of: "a.png", from: model.root, as: "twin.png")

        let review = try await addAndShowReview(model, [twin])
        try Data("changed".utf8).write(to: model.root.appendingPathComponent("a.png"))
        review.toggle(try XCTUnwrap(review.group?.copies.first(where: \.isIncoming)).id)
        review.confirm()
        try await waitUntilDone(model)

        XCTAssertTrue(FileManager.default.fileExists(atPath: twin.path))
        XCTAssertTrue(model.trash.isEmpty)
        XCTAssertNotNil(model.message)
    }

    func testLockingDuringTheReviewEndsItAndReportsNothingAsNotMoved() async throws {
        let model = try await openVault(lockedByTest: true)
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))])
        let twin = try copy(of: "a.png", from: model.root, as: "twin.png")
        let review = try await addAndShowReview(model, [twin])

        await model.lock()

        XCTAssertNil(model.comparison)
        XCTAssertNil(review.group)
        XCTAssertTrue(review.playback.players.isEmpty)
        XCTAssertTrue(model.moveFailures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: twin.path))
        XCTAssertEqual(model.phase, .locked)
    }

    func testADownloadAddedWithoutAskingIsComparedTheNextTimeTheVaultOpens() async throws {
        let model = try await openVault()
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))])
        let downloaded = model.root.appendingPathComponent("downloaded.png")
        try FileManager.default.copyItem(at: model.root.appendingPathComponent("a.png"), to: downloaded)
        model.reload()
        await model.queueDuplicateCheck(of: downloaded)
        await model.lock()

        await model.unlock(password: "dupes-pass")
        model.finishOpening()
        try await waitUntil(timeout: .seconds(30), "the queued download was checked") { model.downloadMatches.count == 1 }
        let shown = try XCTUnwrap(model.downloadMatches.first?.group)
        XCTAssertEqual(shown.copies.map(\.place), [.vault, .downloaded])
        model.reviewDownloads()
        try await waitUntil(timeout: .seconds(30), "the download is shown for a choice") { model.comparison?.group != nil }
        let review = try XCTUnwrap(model.comparison)
        review.toggle(try XCTUnwrap(shown.copies.first).id)
        review.confirm()
        try await waitUntil(timeout: .seconds(30), "the choice is carried out") { model.comparison == nil && model.trash.count == 1 }

        XCTAssertEqual(model.items.map(\.name), ["a.png"])
        let store = try XCTUnwrap(model.duplicatesStore)
        try await waitUntil("the download is no longer queued") { (try? store.pendingReviews().isEmpty) == true }
    }

    func testCancellingTheDownloadComparisonKeepsEveryDownloadNotReachedQueued() async throws {
        let model = try await openVault()
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png")),
                                       VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("b.png"))])
        for name in ["a.png", "b.png"] {
            let downloaded = model.root.appendingPathComponent("downloaded \(name)")
            try FileManager.default.copyItem(at: model.root.appendingPathComponent(name), to: downloaded)
            model.reload()
            await model.queueDuplicateCheck(of: downloaded)
        }
        await model.lock()
        await model.unlock(password: "dupes-pass")
        model.finishOpening()
        try await waitUntil(timeout: .seconds(30), "both downloads were checked") { model.downloadMatches.count == 2 }

        model.reviewDownloads()
        try await waitUntil(timeout: .seconds(30), "the first download is shown") { model.comparison?.group != nil }
        try XCTUnwrap(model.comparison).cancel()
        try await waitUntil(timeout: .seconds(30), "the comparison closed") { model.comparison == nil }

        XCTAssertEqual(model.downloadMatches.count, 2, "downloads never compared were dropped")
        let store = try XCTUnwrap(model.duplicatesStore)
        XCTAssertEqual(try store.pendingReviews().count, 2)
        XCTAssertTrue(model.trash.isEmpty)
    }

    func testDownloadVideoFindsAnExactCopyBesideASameSizedFileThatDiffers() async throws {
        let model = try await openVault()
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))])
        var altered = try Data(contentsOf: model.root.appendingPathComponent("a.png"))
        altered[altered.count - 1] ^= 0xFF
        try altered.write(to: model.root.appendingPathComponent("same size.png"))
        model.reload()
        let download = try copy(of: "a.png", from: model.root, as: "download.png")
        let other = try copy(of: "same size.png", from: model.root, as: "other.png")
        try Data("not the same at all".utf8).write(to: other)

        let holdsDownload = await model.holdsExactCopy(of: download)
        let holdsOther = await model.holdsExactCopy(of: other)

        XCTAssertTrue(holdsDownload)
        XCTAssertFalse(holdsOther)
    }

    func testARenamedDownloadIsStillComparedTheNextTimeTheVaultOpens() async throws {
        let model = try await openVault()
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))])
        let downloaded = model.root.appendingPathComponent("downloaded.png")
        try FileManager.default.copyItem(at: model.root.appendingPathComponent("a.png"), to: downloaded)
        model.reload()
        await model.queueDuplicateCheck(of: downloaded)
        let item = try XCTUnwrap(model.items.first { $0.name == "downloaded.png" })
        _ = try await model.rename(item, to: "beach")
        await model.lock()

        await model.unlock(password: "dupes-pass")
        model.finishOpening()

        try await waitUntil(timeout: .seconds(30), "the renamed download was checked") { model.downloadMatches.count == 1 }
        XCTAssertEqual(model.downloadMatches.first?.group.copies.first { $0.place == .downloaded }?.item.name, "beach.png")
    }

    func testADownloadChoiceThatCouldNotBeCarriedOutStaysQueued() async throws {
        let model = try await openVault()
        try await addAndSettle(model, [VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))])
        let downloaded = model.root.appendingPathComponent("downloaded.png")
        try FileManager.default.copyItem(at: model.root.appendingPathComponent("a.png"), to: downloaded)
        model.reload()
        await model.queueDuplicateCheck(of: downloaded)
        await model.lock()
        await model.unlock(password: "dupes-pass")
        model.finishOpening()
        try await waitUntil(timeout: .seconds(30), "the download was checked") { model.downloadMatches.count == 1 }

        model.reviewDownloads()
        try await waitUntil(timeout: .seconds(30), "the download is shown") { model.comparison?.group != nil }
        try Data("changed meanwhile".utf8).write(to: downloaded)
        let review = try XCTUnwrap(model.comparison)
        review.toggle(try XCTUnwrap(review.group?.copies.first).id)
        review.confirm()
        try await waitUntil(timeout: .seconds(30), "the comparison closed") { model.comparison == nil }

        XCTAssertEqual(model.downloadMatches.count, 1, "a choice that wasn't carried out was dropped")
        XCTAssertEqual(try XCTUnwrap(model.duplicatesStore).pendingReviews().count, 1)
        XCTAssertTrue(model.trash.isEmpty)
    }

    func testADuplicatesReviewBlocksAddsAndALockWaitsForItAndEndsIt() async throws {
        let model = try await openVault(lockedByTest: true)
        let original = try VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("a.png"))
        try FileManager.default.copyItem(at: original, to: model.root.appendingPathComponent("a.png"))
        try FileManager.default.copyItem(at: original, to: model.root.appendingPathComponent("a copy.png"))
        model.reload()
        model.mode = .duplicates
        try await waitUntil(timeout: .seconds(30), "the set is found") { model.duplicateGroups?.count == 1 }
        model.review(try XCTUnwrap(model.duplicateGroups))
        try await waitUntil(timeout: .seconds(30), "the set is shown") { model.comparison?.group != nil }
        let other = try VaultTestMedia.uniquePhoto(at: source.appendingPathComponent("other.png"))

        model.add([other])

        XCTAssertEqual(model.message, VaultMoveError.busy.localizedDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        await model.lock()
        XCTAssertNil(model.comparison)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.phase, .locked)
    }

    private func openVault(lockedByTest: Bool = false) async throws -> VaultModel {
        let model = VaultModel(location: VaultLocation(folder: dir.appendingPathComponent("vault")), watchesSystem: false)
        await model.create(password: "dupes-pass", confirmation: "dupes-pass")
        model.finishOpening()
        if !lockedByTest { addTeardownBlock { @MainActor in await model.lock() } }
        XCTAssertEqual(model.phase, .open)
        return model
    }

    private func addAndSettle(_ model: VaultModel, _ files: [URL]) async throws {
        model.add(files)
        try await waitUntilDone(model)
    }

    private func addAndShowReview(_ model: VaultModel, _ files: [URL]) async throws -> VaultComparison {
        model.add(files)
        try await waitUntil(timeout: .seconds(30), "the copies are shown for a choice") { model.comparison?.group != nil }
        return try XCTUnwrap(model.comparison)
    }

    private func waitUntilDone(_ model: VaultModel) async throws {
        try await waitUntil(timeout: .seconds(30), "the add is done") { model.moveProgress == nil && model.comparison == nil }
    }

    private func copy(of name: String, from origin: URL, as newName: String? = nil, in folder: String? = nil) throws -> URL {
        let base: URL = source
        let target = folder.map { base.appendingPathComponent($0) } ?? base
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let destination = target.appendingPathComponent(newName ?? name)
        try FileManager.default.copyItem(at: origin.appendingPathComponent(name), to: destination)
        return destination
    }

    private func fingerprint(_ url: URL) throws -> [String] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return [url.path, String(values.fileSize ?? -1), String(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
                try VaultMover.sha256(url).base64EncodedString()]
    }
}
