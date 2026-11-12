import ImageIO
import UniformTypeIdentifiers
import VaultSearch
import XCTest
@testable import Toolbox

final class VaultSearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-search-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testMeaningMatchesStandOutAndNamesAlwaysCount() {
        var vectors = VaultVectors()
        let paths = ["dog.jpg"] + (1...24).map { "other\($0).jpg" }
        for path in paths {
            vectors.paths.append(path)
            vectors.modalities.append(.image)
            vectors.starts.append(0)
        }
        let scores: [Float] = [0.9] + (1...24).map { 0.30 + Float($0 % 5) * 0.01 }
        let names = Dictionary(uniqueKeysWithValues: (paths + ["birthday party.mov"]).map { ($0, $0) })

        let byMeaning = VaultRanking.rank(query: "a dog", vectors: vectors, scores: scores, names: names)
        XCTAssertTrue(byMeaning.strong)
        XCTAssertEqual(byMeaning.hits.map(\.path), ["dog.jpg"])

        let byName = VaultRanking.rank(query: "birthday", vectors: vectors, scores: scores, names: names)
        XCTAssertEqual(byName.hits.first?.path, "dog.jpg")
        XCTAssertTrue(byName.hits.contains { $0.path == "birthday party.mov" })
    }

    func testNothingStrongShowsTheClosestFewAsWeakMatches() {
        var vectors = VaultVectors()
        for index in 0..<10 {
            vectors.paths.append("photo\(index).jpg")
            vectors.modalities.append(.image)
            vectors.starts.append(0)
        }
        let scores = [Float](repeating: 0.3, count: 10)
        let result = VaultRanking.rank(query: "volcano", vectors: vectors, scores: scores, names: [:])
        XCTAssertFalse(result.strong)
        XCTAssertEqual(result.hits.count, VaultRanking.closestCount)
    }

    func testAVideoHitPointsAtItsBestMoment() {
        var vectors = VaultVectors()
        vectors.paths = ["clip.mov", "clip.mov", "clip.mov"] + (1...22).map { "p\($0).jpg" }
        vectors.modalities = [.image, .image, .audio] + [Modality](repeating: .image, count: 22)
        vectors.starts = [0, 12, 30] + [Double](repeating: 0, count: 22)
        let scores: [Float] = [0.3, 0.95, 0.3] + [Float](repeating: 0.3, count: 22)
        let result = VaultRanking.rank(query: "zebra", vectors: vectors, scores: scores, names: [:])
        XCTAssertEqual(result.hits.first?.path, "clip.mov")
        XCTAssertEqual(result.hits.first?.start, 12)
    }

    func testIndexKeepsVectorsAndForgetsRemovedFiles() throws {
        let index = try VaultIndex(at: root.appendingPathComponent("index.sqlite"))
        let vector = [Float](repeating: 0.5, count: LlamaEmbedder.dimension)
        try index.store(path: "a.jpg", file: VaultIndexedFile(bytes: 10, modified: 1),
                        segments: [VaultSegment(modality: .image, start: 0, end: 0, vector: vector)])
        try index.store(path: "b.mov", file: VaultIndexedFile(bytes: 20, modified: 2),
                        segments: [VaultSegment(modality: .image, start: 3, end: 6, vector: vector),
                                   VaultSegment(modality: .audio, start: 0, end: 30, vector: vector)])
        XCTAssertEqual(try index.vectors().rows, 3)
        XCTAssertEqual(try index.files()["b.mov"], VaultIndexedFile(bytes: 20, modified: 2))

        try index.remove(["b.mov"])
        let left = try index.vectors()
        XCTAssertEqual(left.paths, ["a.jpg"])
        XCTAssertEqual(Array(left.matrix.prefix(2)), [0.5, 0.5])
        index.close()

        let reopened = try VaultIndex(at: root.appendingPathComponent("index.sqlite"), vectorSource: "a newer model")
        XCTAssertEqual(try reopened.vectors().rows, 0, "vectors from another model must never be mixed in")
    }

    func testSearchFindsTheMatchingPhotoWithTheRealModel() async throws {
        guard let model = EmbeddingModel.locate() else { throw XCTSkip("EmbeddingGemma 2 isn't on this Mac") }
        let red = try makePhoto("one.png", red: 230, green: 20, blue: 20)
        let blue = try makePhoto("two.png", red: 20, green: 40, blue: 230)
        let engine = VaultSearchEngine(root: root, model: model, requiresMountedVolume: false)
        let items = VaultLibrary.items(in: root)

        let pending = try await engine.pending(items)
        XCTAssertEqual(pending.count, 2)
        for item in pending { try await engine.index(item) }
        await engine.finishIndexing()
        let stillPending = try await engine.pending(items)
        XCTAssertTrue(stillPending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.workFolder.path))

        let names = Dictionary(uniqueKeysWithValues: items.map { (engine.relativePath(of: $0.url), $0.name) })
        let redFirst = try await engine.search("a solid red square", names: names)
        let blueFirst = try await engine.search("a solid blue square", names: names)
        XCTAssertEqual(redFirst.hits.first?.path, red.lastPathComponent)
        XCTAssertEqual(blueFirst.hits.first?.path, blue.lastPathComponent)
        engine.close()
    }

    func testNothingIsWrittenWhenTheVaultIsNotMounted() async throws {
        let located = EmbeddingModel.Located(text: root.appendingPathComponent("t.gguf"), media: root.appendingPathComponent("m.gguf"))
        let engine = VaultSearchEngine(root: root, model: located)
        do {
            _ = try await engine.pending([])
            XCTFail("The index opened on a folder that isn't the mounted vault")
        } catch {
            XCTAssertTrue(error is VaultSearchError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.privateFolder.path))
    }

    func testEachEngineHasItsOwnWorkFolderAndClearsOldOnes() async throws {
        let located = EmbeddingModel.Located(text: root.appendingPathComponent("t.gguf"), media: root.appendingPathComponent("m.gguf"))
        let leftover = root.appendingPathComponent(".toolbox/\(VaultSearchEngine.workFolderPrefix)old")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let first = VaultSearchEngine(root: root, model: located, requiresMountedVolume: false)
        let second = VaultSearchEngine(root: root, model: located, requiresMountedVolume: false)
        XCTAssertNotEqual(first.workFolder, second.workFolder)
        _ = try await first.pending([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    func testAModelThatWontLoadStopsIndexingWithAReason() async throws {
        _ = try makePhoto("one.png", red: 200, green: 0, blue: 0)
        let broken = root.appendingPathComponent("broken.gguf")
        try Data("not a model".utf8).write(to: broken)
        let engine = VaultSearchEngine(root: root, model: EmbeddingModel.Located(text: broken, media: broken), requiresMountedVolume: false)
        let item = try XCTUnwrap(VaultLibrary.items(in: root).first)
        do {
            try await engine.index(item)
            XCTFail("A broken model indexed a file")
        } catch VaultSearchError.modelUnavailable {
        } catch {
            XCTFail("Expected modelUnavailable, got \(error)")
        }
    }

    func testModelFilesAreFoundOnlyAtTheirExactSize() throws {
        let folder = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("short".utf8).write(to: folder.appendingPathComponent(EmbeddingModel.text.name))
        try Data("short".utf8).write(to: folder.appendingPathComponent(EmbeddingModel.media.name))
        XCTAssertNil(EmbeddingModel.locate(in: [folder]))
    }

    func testTimesReadLikeAClock() {
        XCTAssertEqual(VaultTime.label(0), "0:00")
        XCTAssertEqual(VaultTime.label(72.9), "1:12")
        XCTAssertEqual(VaultTime.label(3725), "1:02:05")
    }

    @MainActor
    func testClosingAfterASearchIsQuickFromTheMainThread() async throws {
        guard let model = EmbeddingModel.locate() else { throw XCTSkip("EmbeddingGemma 2 isn't on this Mac") }
        _ = try makePhoto("one.png", red: 230, green: 20, blue: 20)
        let engine = VaultSearchEngine(root: root, model: model, requiresMountedVolume: false)
        let items = VaultLibrary.items(in: root)
        for item in try await engine.pending(items) { try await engine.index(item) }
        await engine.finishIndexing()
        _ = try await engine.search("red", names: [:])
        let started = Date()
        engine.close()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "closing the search engine blocked the main thread")
    }

    private func makePhoto(_ name: String, red: UInt8, green: UInt8, blue: UInt8) throws -> URL {
        let url = root.appendingPathComponent(name)
        let side = 512
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side where (128..<384).contains(x) && (128..<384).contains(y) {
                let i = (y * side + x) * 4
                pixels[i] = red
                pixels[i + 1] = green
                pixels[i + 2] = blue
            }
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
