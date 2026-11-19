import XCTest
@testable import Toolbox
import VaultSearch

@MainActor
private final class StandInVault: DownloadVault {
    var acceptsFiles = true
    var refused: Set<String> = []
    var searchable = true
    var locksAfterMoves: Int?
    let root = URL(fileURLWithPath: "/stand-in-vault")
    let events: Locked<[String]>
    private var moves = 0

    init(events: Locked<[String]>) { self.events = events }

    func moveIn(_ file: URL) async throws -> URL {
        guard acceptsFiles else { throw VaultMoveError.vaultNotOpen }
        if refused.contains(file.lastPathComponent) { throw VaultMoveError.unsupportedType }
        let landed = root.appendingPathComponent("vault " + file.lastPathComponent)
        events.update { $0.append("move \(file.lastPathComponent)") }
        moves += 1
        if moves == locksAfterMoves { acceptsFiles = false }
        return landed
    }

    func makeSearchable(_ file: URL) async -> Bool {
        events.update { $0.append("index \(file.lastPathComponent)") }
        return searchable
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
    private var events = Locked<[String]>([])
    private var trashed = Locked<[URL]>([])

    private func makeModel(links: String, addToVault: Bool, defaults: UserDefaults? = nil) async throws -> DownloadVideoModel {
        let events = events, trashed = trashed
        let model = DownloadVideoModel(downloader: NamedByHost(), saveFolder: downloads,
                                       trash: { file in trashed.update { $0.append(file) } },
                                       sendToDrive: { files in
                                           events.update { $0.append("drive " + files.map(\.lastPathComponent).joined(separator: ", ")) }
                                           return DriveSender.Result(copied: files.count, skipped: 0)
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

    func testAddToVaultMovesEachVideoInMakesItSearchableThenSendsTheVaultCopy() async throws {
        let model = try await makeModel(links: "https://a.example.com/1 https://b.example.com/2", addToVault: true)
        let vault = StandInVault(events: events)

        try await send(model, vault: vault)

        XCTAssertEqual(events.value, ["move a.example.com.mp4", "move b.example.com.mp4",
                                      "index vault a.example.com.mp4", "index vault b.example.com.mp4",
                                      "drive vault a.example.com.mp4, vault b.example.com.mp4"])
        XCTAssertEqual(model.items.map(\.state), [.inVault(vault.root.appendingPathComponent("vault a.example.com.mp4")),
                                                  .inVault(vault.root.appendingPathComponent("vault b.example.com.mp4"))])
        XCTAssertEqual(model.sendState, .sent(copied: 2, skipped: 0, vault: VaultSendReport(moved: 2)))
        XCTAssertEqual(model.sendSummary, "Sent 2 to Google Drive")
        XCTAssertEqual(model.finishedCount, 2)
    }

    func testWithoutAddToVaultTheDownloadsAreSentAndTheVaultIsNeverTouched() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: false)
        let vault = StandInVault(events: events)

        try await send(model, vault: vault)

        XCTAssertEqual(events.value, ["drive a.example.com.mp4"])
        XCTAssertEqual(model.items.map(\.state), [.done(downloads.appendingPathComponent("a.example.com.mp4"))])
        XCTAssertEqual(model.sendSummary, "Sent 1 to Google Drive")
    }

    func testALockedVaultStopsTheSendBeforeAnythingMoves() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: true)
        let vault = StandInVault(events: events)
        vault.acceptsFiles = false

        model.sendToGoogle(vault: vault)

        XCTAssertEqual(model.sendState, .failed(DownloadVideoModel.unlockVaultFirst))
        XCTAssertEqual(events.value, [])
        XCTAssertEqual(model.finishedFiles, [downloads.appendingPathComponent("a.example.com.mp4")])
    }

    func testAVideoThatCannotGoInIsNotSentAndAnUnsearchableOneIsReported() async throws {
        let model = try await makeModel(links: "https://a.example.com/1 https://b.example.com/2", addToVault: true)
        let vault = StandInVault(events: events)
        vault.refused = ["b.example.com.mp4"]
        vault.searchable = false

        try await send(model, vault: vault)

        XCTAssertEqual(events.value.last, "drive vault a.example.com.mp4")
        XCTAssertEqual(try model.items.element(at: 1).state, .done(downloads.appendingPathComponent("b.example.com.mp4")))
        XCTAssertEqual(model.sendSummary,
                       "Sent 1 to Google Drive, 1 couldn't go into the Vault and weren't sent, 1 not searchable yet")
    }

    func testNothingIsSentWhenNoVideoGoesIn() async throws {
        let model = try await makeModel(links: "https://a.example.com/1", addToVault: true)
        let vault = StandInVault(events: events)
        vault.refused = ["a.example.com.mp4"]

        try await send(model, vault: vault)

        XCTAssertEqual(events.value, [])
        XCTAssertEqual(model.sendSummary, "Nothing went into the Vault, so nothing was sent")
    }

    func testAVaultThatLocksPartwaySendsNothingToGoogle() async throws {
        let model = try await makeModel(links: "https://a.example.com/1 https://b.example.com/2", addToVault: true)
        let vault = StandInVault(events: events)
        vault.locksAfterMoves = 1

        try await send(model, vault: vault)

        XCTAssertEqual(events.value, ["move a.example.com.mp4"])
        XCTAssertEqual(model.sendState, .failed(DownloadVideoModel.vaultLockedMidway))
        XCTAssertEqual(try model.items.element(at: 1).state, .done(downloads.appendingPathComponent("b.example.com.mp4")))
    }

    func testClearTrashesDownloadsButLeavesVideosInTheVault() async throws {
        let model = try await makeModel(links: "https://a.example.com/1 https://b.example.com/2", addToVault: true)
        let vault = StandInVault(events: events)
        vault.refused = ["b.example.com.mp4"]
        try await send(model, vault: vault)

        model.clearFinished()

        XCTAssertEqual(trashed.value, [downloads.appendingPathComponent("b.example.com.mp4")])
        XCTAssertTrue(model.items.isEmpty)
    }

    func testAudioOnlyDownloadsCannotBeAddedToTheVault() async throws {
        let model = try await makeModel(links: "https://a.example.com/1.m4a", addToVault: false)
        XCTAssertFalse(model.canAddToVault)
        let video = try await makeModel(links: "https://a.example.com/1", addToVault: false)
        XCTAssertTrue(video.canAddToVault)
    }

    func testAddToVaultIsRemembered() async throws {
        let defaults = try makeScratchDefaults()
        _ = try await makeModel(links: "", addToVault: true, defaults: defaults)

        let reopened = DownloadVideoModel(downloader: NamedByHost(), saveFolder: downloads, defaults: defaults)

        XCTAssertTrue(reopened.addToVault)
    }
}

@MainActor
final class VaultMoveInTests: XCTestCase {
    func testMoveInLandsTheFileInTheVaultAndMakeSearchableAnswers() async throws {
        let dir = try makeVaultTestFolder("move-in")
        let model = VaultModel(location: VaultLocation(folder: dir.appendingPathComponent("vault")), watchesSystem: false)
        await model.create(password: "move-in-pass", confirmation: "move-in-pass")
        model.finishOpening()
        addTeardownBlock { @MainActor in await model.lock() }
        let first = dir.appendingPathComponent("one", isDirectory: true), second = dir.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let video = try await VaultTestMedia.video(at: first.appendingPathComponent("clip.mov"), seconds: 1)
        let sameName = try await VaultTestMedia.video(at: second.appendingPathComponent("clip.mov"), seconds: 1)

        let landed = try await model.moveIn(video)
        let renamed = try await model.moveIn(sameName)

        XCTAssertEqual(landed.deletingLastPathComponent().standardizedFileURL, model.root.standardizedFileURL)
        XCTAssertNotEqual(landed, renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
        XCTAssertEqual(Set(model.items.map(\.url.lastPathComponent)), [landed.lastPathComponent, renamed.lastPathComponent])

        let searchable = await model.makeSearchable(landed)
        if EmbeddingModel.locate() == nil {
            XCTAssertFalse(searchable)
            XCTAssertEqual(model.searchState, .needsModel)
        } else {
            XCTAssertTrue(searchable)
            let status = await model.searchStatus(of: try XCTUnwrap(model.items.first { $0.url.standardizedFileURL == landed.standardizedFileURL }))
            guard case .indexed = status else { return XCTFail("the file is not in the index: \(status)") }
        }
        XCTAssertTrue(model.moveFailures.isEmpty)
    }

    func testMoveInRefusesWhileTheVaultIsLocked() async throws {
        let dir = try makeVaultTestFolder("move-in-locked")
        let model = VaultModel(location: VaultLocation(folder: dir.appendingPathComponent("vault")), watchesSystem: false)
        await model.create(password: "move-in-pass", confirmation: "move-in-pass")
        model.finishOpening()
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
        XCTAssertFalse(model.acceptsFiles)
    }
}
