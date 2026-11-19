import CryptoKit
import XCTest
@testable import Toolbox
import VaultSearch

@MainActor
private final class StandInVault: DownloadVault {
    var opening = DownloadVaultOpening.opened
    var acceptsFiles = false
    var refused: Set<String> = []
    var keepsOriginal: Set<String> = []
    var searchable = true
    var locksAfterMoves: Int?
    var locks = true
    let root = URL(fileURLWithPath: "/stand-in-vault")
    let events: Locked<[String]>
    private var moves = 0

    init(events: Locked<[String]>) { self.events = events }

    func openWithTouchID() async -> DownloadVaultOpening {
        events.update { $0.append("touch id") }
        if opening == .opened { acceptsFiles = true }
        return opening
    }

    func moveIn(_ file: URL) async throws -> URL {
        guard acceptsFiles else { throw VaultMoveError.vaultNotOpen }
        if refused.contains(file.lastPathComponent) { throw VaultMoveError.copyDiffers }
        events.update { $0.append("move \(file.lastPathComponent)") }
        if keepsOriginal.contains(file.lastPathComponent) {
            throw VaultMoveError.originalKept("busy", copy: root.appendingPathComponent("vault " + file.lastPathComponent))
        }
        moves += 1
        if moves == locksAfterMoves { acceptsFiles = false }
        return root.appendingPathComponent("vault " + file.lastPathComponent)
    }

    func makeSearchable(_ file: URL) async -> Bool {
        events.update { $0.append("index \(file.lastPathComponent)") }
        return searchable
    }

    func lockAndConfirm() async -> Bool {
        events.update { $0.append("lock") }
        if locks { acceptsFiles = false }
        return locks
    }
}

private struct NamedByHost: Downloader {
    func download(url: URL, options: DownloadOptions, into folder: URL,
                  onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL {
        folder.appendingPathComponent("\(url.host ?? "video").\(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)")
    }
}

@MainActor
final class DownloadToVaultTests: XCTestCase {
    private let downloads = URL(fileURLWithPath: "/stand-in-downloads")
    private let events = Locked<[String]>([])
    private let trashed = Locked<[URL]>([])

    private func makeModel(links: String, addToVault: Bool, defaults: UserDefaults? = nil) async throws -> DownloadVideoModel {
        let events = events, trashed = trashed
        let model = DownloadVideoModel(downloader: NamedByHost(), saveFolder: downloads,
                                       trash: { file in trashed.update { $0.append(file) } },
                                       sendToDrive: { files in
                                           events.update { $0.append("drive " + files.map(\.lastPathComponent).joined(separator: ", ")) }
                                           return DriveSender.Result(copied: files.count)
                                       },
                                       defaults: try defaults ?? makeScratchDefaults())
        model.addToVault = addToVault
        model.linkText = links
        model.start()
        try await waitUntil("the downloads have finished") { !model.isRunning }
        return model
    }

    private func send(_ model: DownloadVideoModel, vault: DownloadVault?) async throws {
        model.sendToGoogle(vault: vault)
        try await waitUntil("the send has finished") { !model.sendState.isBusy }
    }

    private func inDownloads(_ name: String) -> URL { downloads.appendingPathComponent(name) }

    func testTouchIDOpensTheVaultThenEachVideoGoesInIsMadeSearchableIsSentAndTheVaultLocks() async throws {
        let model = try await makeModel(links: "https://a.example.com/1 https://b.example.com/2", addToVault: true)
        let vault = StandInVault(events: events)

        try await send(model, vault: vault)

        XCTAssertEqual(events.value, ["touch id", "move a.example.com.mp4", "move b.example.com.mp4",
                                      "index vault a.example.com.mp4", "index vault b.example.com.mp4",
                                      "drive vault a.example.com.mp4, vault b.example.com.mp4", "lock"])
        XCTAssertEqual(model.items.map(\.state), [.inVault(vault.root.appendingPathComponent("vault a.example.com.mp4")),
                                                  .inVault(vault.root.appendingPathComponent("vault b.example.com.mp4"))])
        XCTAssertEqual(model.sendSummary, "Sent 2 to Google Drive.")
    }

    func testWithoutAddToVaultTheDownloadsAreSentAndTheVaultIsNeverTouched() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: false)

        try await send(model, vault: StandInVault(events: events))

        XCTAssertEqual(events.value, ["drive a.example.com.mp4"])
        XCTAssertEqual(model.items.map(\.state), [.done(inDownloads("a.example.com.mp4"))])
    }

    func testWhenTouchIDFailsTheVideosAreStillSentButNotAdded() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: true)
        let vault = StandInVault(events: events)
        vault.opening = .unavailable("Touch ID didn't recognize your finger.")

        try await send(model, vault: vault)

        XCTAssertEqual(events.value, ["touch id", "drive a.example.com.mp4"], "a vault Touch ID never opened is not locked")
        XCTAssertEqual(model.items.map(\.state), [.done(inDownloads("a.example.com.mp4"))])
        XCTAssertEqual(model.sendSummary,
                       "Sent 1 to Google Drive. Not added to the Vault: Touch ID didn't recognize your finger.")
    }

    func testAFailedUnlockThatLeftTheVaultOpenSaysSo() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: true)
        let vault = StandInVault(events: events)
        vault.opening = .unavailable("The Vault didn't open.", stillOpen: true)

        try await send(model, vault: vault)

        XCTAssertEqual(events.value, ["touch id", "drive a.example.com.mp4"])
        XCTAssertEqual(model.sendSummary, DownloadVideoModel.vaultStillOpen
                       + " Sent 1 to Google Drive. Not added to the Vault: The Vault didn't open.")
    }

    func testAVaultLeftOpenIsReportedEvenWhenOnlyVaultVideosWereListed() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: true)
        try await send(model, vault: StandInVault(events: events))
        let vault = StandInVault(events: events)
        vault.opening = .unavailable("The Vault didn't open.", stillOpen: true)

        try await send(model, vault: vault)

        XCTAssertEqual(model.sendState, .failed(DownloadVideoModel.vaultStillOpen
                                                + " These videos are in the Vault and weren't sent. The Vault didn't open."))
    }

    func testCancellingTouchIDSendsNothing() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: true)
        let vault = StandInVault(events: events)
        vault.opening = .cancelled

        try await send(model, vault: vault)

        XCTAssertEqual(events.value, ["touch id"])
        XCTAssertEqual(model.sendState, .failed(DownloadVideoModel.touchIDCancelled))
    }

    func testAVideoTheVaultRefusesIsNotSentAndSaysWhy() async throws {
        let model = try await makeModel(links: "https://a.example.com/1 https://b.example.com/2", addToVault: true)
        let vault = StandInVault(events: events)
        vault.refused = ["b.example.com.mp4"]
        vault.searchable = false

        try await send(model, vault: vault)

        XCTAssertEqual(events.value.suffix(2), ["drive vault a.example.com.mp4", "lock"])
        let refused = try model.items.element(at: 1)
        XCTAssertEqual(refused.state, .done(inDownloads("b.example.com.mp4")))
        XCTAssertEqual(refused.vaultProblem, VaultMoveError.copyDiffers.localizedDescription)
        XCTAssertEqual(model.sendSummary,
                       "Sent 1 to Google Drive, 1 couldn't go into the Vault and weren't sent, 1 not searchable yet.")
    }

    func testAVideoInTheVaultWhoseOriginalStayedCountsAsMovedAndIsSentOnce() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: true)
        let vault = StandInVault(events: events)
        vault.keepsOriginal = ["a.example.com.mp4"]

        try await send(model, vault: vault)

        XCTAssertEqual(events.value, ["touch id", "move a.example.com.mp4", "index vault a.example.com.mp4",
                                      "drive vault a.example.com.mp4", "lock"])
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.state, .inVault(vault.root.appendingPathComponent("vault a.example.com.mp4")))
        XCTAssertEqual(item.vaultProblem, "The copy in Downloads couldn't be deleted, so Clear leaves it there: busy")
    }

    func testAudioGoesStraightFromDownloadsAndNeverAsksForTouchID() async throws {
        let model = try await makeModel(links: "https://a.example.com/1.m4a", addToVault: true)

        try await send(model, vault: StandInVault(events: events))

        XCTAssertEqual(events.value, ["drive a.example.com.m4a"])
    }

    func testAudioInAMixedBatchIsSentFromDownloadsBesideTheVaultCopies() async throws {
        let model = try await makeModel(links: "https://a.example.com/1.m4a https://b.example.com/2", addToVault: true)

        try await send(model, vault: StandInVault(events: events))

        XCTAssertTrue(events.value.contains("drive a.example.com.m4a, vault b.example.com.mp4"), "\(events.value)")
        XCTAssertEqual(events.value.last, "lock")
    }

    func testAVaultThatLocksPartwaySendsTheRestFromDownloadsAndSaysWhatWasLeft() async throws {
        let model = try await makeModel(links: "https://a.example.com/1 https://b.example.com/2", addToVault: true)
        let vault = StandInVault(events: events)
        vault.locksAfterMoves = 1

        try await send(model, vault: vault)

        XCTAssertEqual(events.value, ["touch id", "move a.example.com.mp4", "drive b.example.com.mp4", "lock"])
        XCTAssertEqual(model.sendSummary,
                       "Sent 1 to Google Drive, 1 in the Vault weren't sent because it locked; send again.")
    }

    func testAVaultThatWillNotLockSaysSoFirst() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: true)
        let vault = StandInVault(events: events)
        vault.locks = false

        try await send(model, vault: vault)

        XCTAssertEqual(model.sendSummary, DownloadVideoModel.vaultStillOpen + " Sent 1 to Google Drive.")
    }

    func testTheVaultLocksEvenWhenGoogleDriveFails() async throws {
        let model = DownloadVideoModel(downloader: NamedByHost(), saveFolder: downloads,
                                       sendToDrive: { _ in throw DriveSender.DriveError.notMounted },
                                       defaults: try makeScratchDefaults())
        model.addToVault = true
        model.linkText = "https://a.example.com/1"
        model.start()
        try await waitUntil("the download has finished") { !model.isRunning }
        let vault = StandInVault(events: events)

        try await send(model, vault: vault)

        XCTAssertEqual(events.value.last, "lock")
        XCTAssertEqual(model.sendState, .failed(DriveSender.DriveError.notMounted.localizedDescription))
    }

    func testVideosAlreadyInTheVaultNeedAddToVaultToBeSent() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: true)
        try await send(model, vault: StandInVault(events: events))
        model.addToVault = false
        events.update { $0 = [] }

        try await send(model, vault: StandInVault(events: events))

        XCTAssertEqual(events.value, [])
        XCTAssertEqual(model.sendState, .failed(DownloadVideoModel.onlyInVault))
    }

    func testClearTrashesDownloadsButLeavesVideosInTheVault() async throws {
        let model = try await makeModel(links: "https://a.example.com/1 https://b.example.com/2", addToVault: true)
        let vault = StandInVault(events: events)
        vault.refused = ["b.example.com.mp4"]
        try await send(model, vault: vault)

        model.clearFinished()

        XCTAssertEqual(trashed.value, [inDownloads("b.example.com.mp4")])
        XCTAssertTrue(model.items.isEmpty)
    }

    func testNoDownloadStartsWhileASendIsRunning() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: true)
        let vault = StandInVault(events: events)
        vault.opening = .cancelled
        model.sendToGoogle(vault: vault)
        model.linkText = "https://b.example.com/2"

        XCTAssertTrue(model.sendState.isBusy)
        XCTAssertFalse(model.canStart)
        try await waitUntil("the send has finished") { !model.sendState.isBusy }
        XCTAssertTrue(model.canStart)
    }

    func testAddToVaultIsRemembered() async throws {
        let defaults = try makeScratchDefaults()
        _ = try await makeModel(links: "", addToVault: true, defaults: defaults)

        let reopened = DownloadVideoModel(downloader: NamedByHost(), saveFolder: downloads, defaults: defaults)

        XCTAssertTrue(reopened.addToVault)
    }
}

@MainActor
private final class StandInKeeper: VaultPasswordKeeper {
    var answer: VaultKeyAnswer
    var saved: String?
    var isAvailable: Bool { true }
    var hasPassword: Bool { saved != nil }

    init(answer: VaultKeyAnswer, saved: String? = "stand-in") {
        self.answer = answer
        self.saved = saved
    }

    func save(_ password: String) throws { saved = password }
    func forget() { saved = nil }
    func password(reason: String) async -> VaultKeyAnswer { answer }
}

@MainActor
final class VaultMoveInTests: XCTestCase {
    private static let password = "move-in-pass"

    private func makeVault(_ name: String, keeper: StandInKeeper) async throws -> (VaultModel, URL) {
        let dir = try makeVaultTestFolder(name)
        let model = VaultModel(location: VaultLocation(folder: dir.appendingPathComponent("vault")), watchesSystem: false,
                               passwordKeeper: keeper)
        await model.create(password: Self.password, confirmation: Self.password)
        model.finishOpening()
        addTeardownBlock { @MainActor in await model.lock() }
        return (model, dir)
    }

    func testTouchIDOpensTheVaultAndLockAndConfirmLeavesItLocked() async throws {
        let keeper = StandInKeeper(answer: .password(Self.password))
        let (model, dir) = try await makeVault("touch-open", keeper: keeper)
        await model.lock()
        XCTAssertFalse(model.acceptsFiles)

        let opening = await model.openWithTouchID()

        XCTAssertEqual(opening, .opened)
        XCTAssertTrue(model.acceptsFiles)
        XCTAssertTrue(model.disk.isOpen)
        let video = try await VaultTestMedia.video(at: dir.appendingPathComponent("clip.mov"), seconds: 1)
        let landed = try await model.moveIn(video)
        XCTAssertTrue(model.items.contains { $0.url.standardizedFileURL == landed.standardizedFileURL })

        let locked = await model.lockAndConfirm()

        XCTAssertTrue(locked)
        XCTAssertFalse(model.disk.isOpen)
        XCTAssertEqual(model.door.state, .closed)
        XCTAssertEqual(model.phase, .locked)
    }

    func testAWrongSavedPasswordForgetsItAndLeavesNoMessageOnTheDoor() async throws {
        let keeper = StandInKeeper(answer: .password("not-the-password"))
        let (model, _) = try await makeVault("touch-wrong", keeper: keeper)
        await model.lock()

        let opening = await model.openWithTouchID()

        guard case .unavailable = opening else { return XCTFail("a wrong password opened the vault: \(opening)") }
        XCTAssertFalse(keeper.hasPassword)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.wrongPasswordAttempts, 0)
        XCTAssertFalse(model.disk.isOpen)
    }

    func testCancelledOrFailedTouchIDLeavesTheVaultLocked() async throws {
        let keeper = StandInKeeper(answer: .cancelled)
        let (model, _) = try await makeVault("touch-cancel", keeper: keeper)
        await model.lock()

        let cancelled = await model.openWithTouchID()
        keeper.answer = .failed("Touch ID didn't recognize your finger.")
        let failed = await model.openWithTouchID()

        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(failed, .unavailable("Touch ID didn't recognize your finger."))
        XCTAssertFalse(model.disk.isOpen)
        XCTAssertTrue(keeper.hasPassword, "a missed finger is not a reason to forget the password")
    }

    func testUntickingTouchIDForgetsThePasswordAtOnce() async throws {
        let keeper = StandInKeeper(answer: .password(Self.password))
        let (model, _) = try await makeVault("touch-untick", keeper: keeper)
        model.usesTouchID = true
        await model.lock()

        model.usesTouchID = false
        let opening = await model.openWithTouchID()

        XCTAssertNil(keeper.saved)
        XCTAssertEqual(opening, .unavailable(VaultTouchIDKey.notSetUp))
        XCTAssertFalse(model.disk.isOpen)
    }

    func testAPasswordChangeReSealsTheSavedPassword() async throws {
        let keeper = StandInKeeper(answer: .cancelled)
        let (model, _) = try await makeVault("touch-change", keeper: keeper)
        model.usesTouchID = true
        await model.lock()
        await model.unlock(password: Self.password)
        XCTAssertEqual(keeper.saved, Self.password)

        let changed = await model.changePassword(current: Self.password, new: "changed-pass-9", confirmation: "changed-pass-9")

        XCTAssertTrue(changed)
        XCTAssertEqual(keeper.saved, "changed-pass-9")
    }

    func testASearchWaitThatRunsOutAnswersNotSearchable() async throws {
        guard EmbeddingModel.locate() != nil else { throw XCTSkip("EmbeddingGemma 2 isn't on this Mac") }
        let (model, dir) = try await makeVault("search-limit", keeper: StandInKeeper(answer: .cancelled))
        model.searchWaitLimit = .milliseconds(1)
        let video = try await VaultTestMedia.video(at: dir.appendingPathComponent("long.mov"), seconds: 20)
        let landed = try await model.moveIn(video)

        let searchable = await model.makeSearchable(landed)

        XCTAssertFalse(searchable)
    }

    func testUnlockingSavesThePasswordOnlyWhenTouchIDIsTicked() async throws {
        let keeper = StandInKeeper(answer: .cancelled, saved: nil)
        let (model, _) = try await makeVault("touch-save", keeper: keeper)
        XCTAssertNil(keeper.saved)
        await model.lock()

        model.usesTouchID = true
        await model.unlock(password: Self.password)
        XCTAssertEqual(keeper.saved, Self.password)
        await model.lock()

        model.usesTouchID = false
        await model.unlock(password: Self.password)
        XCTAssertNil(keeper.saved)
    }

    func testMoveInLandsTheFileInTheVaultAndMakeSearchableAnswers() async throws {
        let (model, dir) = try await makeVault("move-in", keeper: StandInKeeper(answer: .cancelled))
        let first = dir.appendingPathComponent("one", isDirectory: true), second = dir.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let video = try await VaultTestMedia.video(at: first.appendingPathComponent("clip.mov"), seconds: 1)
        let sameName = try await VaultTestMedia.video(at: second.appendingPathComponent("clip.mov"), seconds: 1)

        let landed = try await model.moveIn(video)
        let renamed = try await model.moveIn(sameName)

        XCTAssertNotEqual(landed, renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
        XCTAssertTrue(model.items.contains { $0.url.standardizedFileURL == landed.standardizedFileURL })
        XCTAssertNil(model.moveProgress)

        let searchable = await model.makeSearchable(landed)
        if EmbeddingModel.locate() == nil {
            XCTAssertFalse(searchable)
            XCTAssertEqual(model.searchState, .needsModel)
        } else {
            XCTAssertTrue(searchable)
            let status = await model.searchStatus(of: try XCTUnwrap(model.items.first { $0.url.standardizedFileURL == landed.standardizedFileURL }))
            guard case .indexed = status else { return XCTFail("the file is not in the index: \(status)") }
        }
    }

    func testLockingAnswersWhoeverWaitsForSearch() async throws {
        guard EmbeddingModel.locate() != nil else { throw XCTSkip("EmbeddingGemma 2 isn't on this Mac") }
        let (model, dir) = try await makeVault("search-wait", keeper: StandInKeeper(answer: .cancelled))
        let video = try await VaultTestMedia.video(at: dir.appendingPathComponent("long.mov"), seconds: 20)
        let landed = try await model.moveIn(video)

        let waiting = Task { await model.makeSearchable(landed) }
        try await waitUntil("indexing has started") { if case .indexing = model.searchState { true } else { false } }
        await model.lock()

        let searchable = await waiting.value
        XCTAssertFalse(searchable)
    }

    func testMoveInRefusesWhileTheVaultIsLocked() async throws {
        let (model, dir) = try await makeVault("move-in-locked", keeper: StandInKeeper(answer: .cancelled))
        await model.lock()
        let video = try await VaultTestMedia.video(at: dir.appendingPathComponent("clip.mov"), seconds: 1)

        do {
            _ = try await model.moveIn(video)
            XCTFail("a locked vault took a file")
        } catch {
            XCTAssertEqual(error as? VaultMoveError, .vaultNotOpen)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
        let searchable = await model.makeSearchable(video)
        XCTAssertFalse(searchable)
    }
}

@MainActor
final class VaultTouchIDKeyTests: XCTestCase {
    func testASealedPasswordOpensOnlyWithItsOwnKey() throws {
        let key = P256.KeyAgreement.PrivateKey(), stranger = P256.KeyAgreement.PrivateKey()
        let sealed = try VaultTouchIDKey.seal("round-trip-pass", to: key.publicKey, enclaveKey: Data())

        XCTAssertEqual(try VaultTouchIDKey.unseal(sealed) { try key.sharedSecretFromKeyAgreement(with: $0) }, "round-trip-pass")
        XCTAssertThrowsError(try VaultTouchIDKey.unseal(sealed) { try stranger.sharedSecretFromKeyAgreement(with: $0) })
        XCTAssertNil(sealed.box.range(of: Data("round-trip-pass".utf8)))
    }

    func testAVaultFileNameNeverReachesTheLogs() {
        let original = URL(fileURLWithPath: "/Users/someone/Downloads/My Clip [abc].mp4")
        let copy = URL(fileURLWithPath: "/Users/someone/Library/Open.noindex/My Clip [abc].mp4")
        let error = VaultMoveError.originalKept("“My Clip [abc].mp4” couldn't be removed.", copy: copy)

        let logged = VaultLog.details(error, file: original).values.joined(separator: " ")

        XCTAssertFalse(logged.contains("My Clip"), logged)
        XCTAssertFalse(logged.contains("My%20Clip"), logged)
    }

    func testThePasswordIsSavedSealedAndForgotten() throws {
        guard SecureEnclave.isAvailable, VaultTouchIDKey(file: URL(fileURLWithPath: "/dev/null")).isAvailable else {
            throw XCTSkip("No Touch ID on this Mac")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("touch-key-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let key = VaultTouchIDKey(file: folder.appendingPathComponent(VaultTouchIDKey.fileName))
        XCTAssertFalse(key.hasPassword)

        try key.save("sealed-pass-123")

        XCTAssertTrue(key.hasPassword)
        let stored = try Data(contentsOf: folder.appendingPathComponent(VaultTouchIDKey.fileName))
        XCTAssertNil(stored.range(of: Data("sealed-pass-123".utf8)), "the password is stored in the clear")
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(VaultTouchIDKey.fileName).path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        key.forget()
        XCTAssertFalse(key.hasPassword)
    }
}
