import AVFoundation
import VaultSearch
import XCTest
@testable import Toolbox

final class VaultPlayableTests: XCTestCase {
    private var root: URL!
    private var privateFolder: URL { root.appendingPathComponent(VaultLibrary.privateFolderName) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-playable-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testProbeOutputGivesTheFirstSoundCodec() {
        XCTAssertEqual(VaultPlayable.firstCodec(inProbeOutput: "mp3\n"), "mp3")
        XCTAssertEqual(VaultPlayable.firstCodec(inProbeOutput: "aac,\naac\n"), "aac")
        XCTAssertNil(VaultPlayable.firstCodec(inProbeOutput: "\n"))
    }

    func testTheCopyKeepsTheStreamsAsTheyAre() {
        let arguments = VaultPlayable.remuxArguments(from: URL(fileURLWithPath: "/v/in.mp4"), to: URL(fileURLWithPath: "/v/out.mov"))
        XCTAssertTrue(arguments.contains("copy"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("lib") })
        XCTAssertEqual(Array(arguments.suffix(3)), ["-f", "mov", "/v/out.mov"])
    }

    func testHiddenMP3SoundGetsAPlayableCopyAndTheOriginalIsUntouched() async throws {
        let tools = try Self.tools()
        let item = try placeFixture()
        let before = try VaultMover.sha256(item.url)
        let avFoundationHearsTheOriginal = await VaultPlayable.avFoundationHearsSound(item.url)
        XCTAssertFalse(avFoundationHearsTheOriginal, "The fixture should reproduce the silent-video bug")
        let needsCopy = await VaultPlayable.needsCopy(item, privateFolder: privateFolder, tools: tools)
        XCTAssertTrue(needsCopy)

        let playable = await VaultPlayable.url(for: item, privateFolder: privateFolder, tools: tools)

        XCTAssertEqual(playable, VaultPlayable.copyURL(for: item, privateFolder: privateFolder))
        let hearsTheCopy = await VaultPlayable.avFoundationHearsSound(playable)
        XCTAssertTrue(hearsTheCopy)
        XCTAssertEqual(try VaultMover.sha256(item.url), before)
        let stillNeedsCopy = await VaultPlayable.needsCopy(item, privateFolder: privateFolder, tools: tools)
        XCTAssertFalse(stillNeedsCopy)
        let again = await VaultPlayable.url(for: item, privateFolder: privateFolder, tools: tools)
        XCTAssertEqual(again, playable)
    }

    func testSearchCanReadTheSoundThroughTheCopy() async throws {
        let tools = try Self.tools()
        let item = try placeFixture()
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let fromOriginal = try await MediaPieces.soundtrack(of: item.url, to: work)
        let playable = await VaultPlayable.url(for: item, privateFolder: privateFolder, tools: tools)
        let fromCopy = try await MediaPieces.soundtrack(of: playable, to: work)

        XCTAssertTrue(fromOriginal.isEmpty)
        XCTAssertFalse(fromCopy.isEmpty)
    }

    func testVideosWithoutSoundAreLeftAlone() async throws {
        let tools = try Self.tools()
        _ = try await VaultTestMedia.video(at: root.appendingPathComponent("quiet.mov"), seconds: 1)
        let item = try XCTUnwrap(VaultLibrary.items(in: root).first)

        let playable = await VaultPlayable.url(for: item, privateFolder: privateFolder, tools: tools)

        XCTAssertEqual(playable, item.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultPlayable.folder(in: privateFolder).path))
    }

    func testCopiesOfRemovedVideosArePruned() throws {
        let kept = try placeFixture()
        let folder = VaultPlayable.folder(in: privateFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keptCopy = VaultPlayable.copyURL(for: kept, privateFolder: privateFolder)
        let orphan = folder.appendingPathComponent("orphan.mov")
        for file in [keptCopy, orphan] { try Data("x".utf8).write(to: file) }

        VaultPlayable.prune(keeping: [kept], privateFolder: privateFolder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keptCopy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    private func placeFixture() throws -> VaultItem {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hevc-mp3-sound.mp4")
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("clip.mp4"))
        return try XCTUnwrap(VaultLibrary.items(in: root).first { $0.name == "clip.mp4" })
    }

    /// The app's own ffmpeg build (scripts/fetch-tools.sh, as CI does) or Homebrew's.
    static func tools() throws -> MediaTools {
        if let found = MediaTools.find() { return found }
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../build/tools").standardizedFileURL
        let tools = MediaTools(ffmpeg: built.appendingPathComponent("ffmpeg"), ffprobe: built.appendingPathComponent("ffprobe"))
        guard FileManager.default.isExecutableFile(atPath: tools.ffmpeg.path),
              FileManager.default.isExecutableFile(atPath: tools.ffprobe.path) else {
            let missing = "ffmpeg not found: run scripts/fetch-tools.sh or brew install ffmpeg"
            if ProcessInfo.processInfo.environment["CI"] == "true" { throw ToolsMissing(message: missing) }
            throw XCTSkip(missing)
        }
        return tools
    }
}

private struct ToolsMissing: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
