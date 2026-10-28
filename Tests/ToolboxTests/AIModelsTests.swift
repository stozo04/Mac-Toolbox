import XCTest
@testable import Toolbox

final class AIModelsTests: XCTestCase {
    private var home: URL!
    private var central: URL { home.appendingPathComponent("Library/Application Support/Toolbox/AI Models") }
    private var support: URL { home.appendingPathComponent("Library/Application Support") }

    override func setUpWithError() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("ai-models-\(UUID())")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        home = made.resolvingSymlinksInPath()  // /var is a link to /private/var
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    private func scan(extra: [URL] = []) -> [InstalledModel] { ModelScanner(home: home, central: central, extraPaths: extra).scan() }

    // MARK: Fixtures

    /// A GGUF file: a real header (architecture, name, tensor count) padded to `megabytes`.
    @discardableResult
    private func makeGGUF(_ url: URL, arch: String = "llama", name: String? = nil, tensors: UInt64 = 10, megabytes: Int = 2) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func string(_ s: String) -> Data { u64(UInt64(s.utf8.count)) + Data(s.utf8) }
        var pairs = [("general.architecture", arch)]
        if let name { pairs.append(("general.name", name)) }
        var data = Data("GGUF".utf8) + u32(3) + u64(tensors) + u64(UInt64(pairs.count))
        for (key, value) in pairs { data += string(key) + u32(8) + string(value) }
        try data.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(megabytes) << 20)
        try handle.close()
        return url
    }

    private func makeFile(_ url: URL, megabytes: Int = 2) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(megabytes) << 20)
        try handle.close()
    }

    private func makeBundle(_ url: URL, megabytes: Int = 2) throws { try makeFile(url.appendingPathComponent("weights.bin"), megabytes: megabytes) }

    private var digUpModels: URL { support.appendingPathComponent("DigUp/Models") }

    private func makeDigUp() throws {
        try makeGGUF(digUpModels.appendingPathComponent("embeddinggemma-2-Q8_0.gguf"), arch: "gemma-embedding", name: "EmbeddingGemma 2")
        try makeGGUF(digUpModels.appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf"), arch: "clip", megabytes: 3)
    }

    // MARK: GGUF

    func testReadsAGGUFHeader() throws {
        let file = try makeGGUF(home.appendingPathComponent("a.gguf"), arch: "qwen2", name: "Qwen2 7B", tensors: 291)
        let info = try XCTUnwrap(GGUFInfo.read(file))
        XCTAssertEqual([info.architecture, info.name], ["qwen2", "Qwen2 7B"])
        XCTAssertEqual(info.tensorCount, 291)
        XCTAssertFalse(info.isVocabularyOnly)
        XCTAssertTrue(try XCTUnwrap(GGUFInfo.read(try makeGGUF(home.appendingPathComponent("v.gguf"), tensors: 0))).isVocabularyOnly)
        try makeFile(home.appendingPathComponent("not.gguf"))
        XCTAssertNil(GGUFInfo.read(home.appendingPathComponent("not.gguf")))
        XCTAssertNil(GGUFInfo.read(home.appendingPathComponent("missing.gguf")))
    }

    // MARK: What each model is

    func testFindsDigUpsTwoModelsAndSaysWhatTheyDo() throws {
        try makeDigUp()
        let models = scan()
        XCTAssertEqual(models.count, 2)
        let text = try XCTUnwrap(models.first { $0.name == "EmbeddingGemma 2 (text)" })
        let media = try XCTUnwrap(models.first { $0.name == "EmbeddingGemma 2 (images and audio)" })
        for model in [text, media] {
            XCTAssertEqual(model.owner, "DigUp")
            XCTAssertEqual(model.kind, .embedding)
            XCTAssertEqual(model.format, "GGUF")
            XCTAssertEqual(model.movability, .movable)
            XCTAssertTrue(model.tags.contains("Q8_0"), "\(model.tags)")
            XCTAssertTrue(model.summary.contains("DigUp"))
        }
        XCTAssertEqual(text.url, digUpModels.appendingPathComponent("embeddinggemma-2-Q8_0.gguf"))
        XCTAssertEqual(text.location, digUpModels)
        XCTAssertEqual(media.bytes, 3 << 20)
    }

    func testGroupsThePiecesOfACoreMLPipelineAndTFLiteFiles() throws {
        let base = support.appendingPathComponent("superwhisper/models/argmaxinc/speakerkit-coreml")
        try makeBundle(base.appendingPathComponent("speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc"))
        try makeBundle(base.appendingPathComponent("speaker_segmenter/pyannote-v3/W32A32/SpeakerSegmenter.mlmodelc"))
        try makeBundle(base.appendingPathComponent("speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc"))
        try makeBundle(support.appendingPathComponent("FluidAudio/Models/silero-vad/silero-vad-unified.mlmodelc"))
        try makeFile(support.appendingPathComponent("Google/Chrome/optimization_guide_model_store/43/AB/model.tflite"), megabytes: 6)
        try makeFile(support.appendingPathComponent("Google/Chrome/optimization_guide_model_store/53/CD/model.tflite"), megabytes: 6)

        let models = scan()
        let speaker = try XCTUnwrap(models.first { $0.name == "argmaxinc / speakerkit-coreml" })
        XCTAssertEqual(speaker.parts, 3)
        XCTAssertEqual(speaker.bytes, 6 << 20)
        XCTAssertEqual(speaker.owner, "superwhisper")
        XCTAssertEqual(speaker.kind, .speech)
        XCTAssertTrue(speaker.summary.contains("who is speaking"))
        XCTAssertEqual(speaker.movability, .managed("Several files that belong together; superwhisper expects them where they are."))
        let vad = try XCTUnwrap(models.first { $0.name == "Silero VAD" })
        XCTAssertEqual(vad.parts, 1)
        XCTAssertFalse(vad.tags.contains { $0.contains("parts") }, "one part is not worth a tag")
        XCTAssertEqual(vad.owner, "FluidAudio")
        XCTAssertTrue(vad.summary.contains("speaking"))
        let chrome = try XCTUnwrap(models.first { $0.owner == "Google Chrome" })
        XCTAssertEqual(chrome.parts, 2, "Chrome's small models read as one")
        XCTAssertEqual(chrome.name, "Chrome on-device models")
        XCTAssertEqual(models.count, 3)
    }

    func testSkipsTokenizerOnlyFilesTinyFilesAndPartialDownloads() throws {
        try makeGGUF(digUpModels.appendingPathComponent("ggml-vocab-llama.gguf"), tensors: 0)
        try makeGGUF(digUpModels.appendingPathComponent("tiny.gguf"), megabytes: 0)
        try makeFile(digUpModels.appendingPathComponent("embeddinggemma-2-Q8_0.gguf.partial"), megabytes: 5)
        try makeFile(digUpModels.appendingPathComponent("notes.txt"), megabytes: 5)
        XCTAssertEqual(scan().count, 0)
    }

    func testReadsTheHuggingFaceCacheAndOllamaLibrary() throws {
        let repo = home.appendingPathComponent(".cache/huggingface/hub/models--BAAI--bge-small-en-v1.5")
        try makeFile(repo.appendingPathComponent("blobs/abc123"), megabytes: 4)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("snapshots/rev1"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("snapshots/rev1/model.safetensors"), withDestinationURL: repo.appendingPathComponent("blobs/abc123"))

        let ollama = home.appendingPathComponent(".ollama/models")
        try makeGGUF(ollama.appendingPathComponent("blobs/sha256-feed"), arch: "llama", name: "Llama 3.2 3B", megabytes: 3)
        let manifest = ollama.appendingPathComponent("manifests/registry.ollama.ai/library/llama3.2/latest")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:feed","size":3145728},{"mediaType":"application/vnd.ollama.image.params","digest":"sha256:p","size":100}]}"#
        try json.write(to: manifest, atomically: true, encoding: .utf8)

        let models = scan()
        let hf = try XCTUnwrap(models.first { $0.owner == "Hugging Face" })
        XCTAssertEqual(hf.name, "BAAI/bge-small-en-v1.5")
        XCTAssertEqual(hf.format, "Safetensors")
        XCTAssertEqual(hf.kind, .embedding)
        XCTAssertEqual(hf.bytes, 4 << 20)
        let llama = try XCTUnwrap(models.first { $0.owner == "Ollama" })
        XCTAssertEqual(llama.name, "llama3.2:latest")
        XCTAssertEqual(llama.kind, .language)
        XCTAssertEqual(llama.bytes, 3_145_828)
        for model in [hf, llama] { if case .managed = model.movability {} else { XCTFail("\(model.name) must stay where its tool keeps it") } }
    }

    func testFindsLooseFilesButNotOnesInsideAppsOrProjects() throws {
        let downloads = home.appendingPathComponent("Downloads")
        let loose = try makeGGUF(downloads.appendingPathComponent("Mistral-7B-Instruct-Q4_K_M.gguf"), arch: "llama", megabytes: 6)
        let insideApp = try makeGGUF(home.appendingPathComponent("Games/Some.app/Contents/Resources/x.gguf"), megabytes: 6)
        let inProject = try makeGGUF(home.appendingPathComponent("Projects/app/node_modules/pkg/y.gguf"), megabytes: 6)
        let small = try makeGGUF(downloads.appendingPathComponent("small.gguf"), megabytes: 2)

        let models = scan(extra: [loose, insideApp, inProject, small])
        XCTAssertEqual(models.count, 1)
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.name, "Mistral 7B Instruct")
        XCTAssertNil(model.owner)
        XCTAssertEqual(model.movability, .movable)
        XCTAssertEqual(model.kind, .language)
        XCTAssertTrue(model.tags.contains("Q4_K_M"))
    }

    func testAddingAndRemovingAFileChangesTheNextScan() throws {
        try makeDigUp()
        XCTAssertEqual(scan().count, 2)
        try FileManager.default.removeItem(at: digUpModels.appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf"))
        XCTAssertEqual(scan().map(\.name), ["EmbeddingGemma 2 (text)"])
        try makeGGUF(support.appendingPathComponent("NewApp/Models/llama.gguf"), megabytes: 4)
        XCTAssertEqual(Set(scan().compactMap(\.owner)), ["DigUp", "NewApp"], "a new app's models folder is found without being listed anywhere")
    }

    // MARK: Moving to the central folder

    func testMovingLeavesALinkThatStillWorksAndTheScanShowsOneModel() throws {
        try makeDigUp()
        let original = digUpModels.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
        let model = try XCTUnwrap(scan().first { $0.url == original })
        let mover = ModelMover(central: central)

        let target = try mover.move(model)

        XCTAssertEqual(target, central.appendingPathComponent("DigUp/embeddinggemma-2-Q8_0.gguf"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: original.path), target.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "DigUp's own check, fileExists, follows the link")
        XCTAssertEqual(size(of: original), 2 << 20, "the same size through the old path")
        XCTAssertEqual(try FileHandle(forReadingFrom: original).read(upToCount: 4), Data("GGUF".utf8), "readable through the old path")

        let after = scan()
        XCTAssertEqual(after.count, 2, "the link does not make a second copy")
        let moved = try XCTUnwrap(after.first { $0.url == target })
        XCTAssertEqual(moved.movability, .central)
        XCTAssertEqual(moved.owner, "DigUp")
        XCTAssertEqual(moved.linkedFrom, [original])
        XCTAssertEqual(moved.name, "EmbeddingGemma 2 (text)")
        XCTAssertEqual(after.filter { $0.movability == .movable }.count, 1, "the other file can still be moved")
    }

    func testMovingBackRestoresTheOriginalFile() throws {
        try makeDigUp()
        let original = digUpModels.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
        let mover = ModelMover(central: central)
        try mover.move(try XCTUnwrap(scan().first { $0.url == original }))
        let moved = try XCTUnwrap(scan().first { $0.movability == .central && $0.url.lastPathComponent == original.lastPathComponent })

        try mover.moveBack(moved)

        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: original.path), "a real file again")
        XCTAssertEqual(size(of: original), 2 << 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: central.appendingPathComponent("DigUp/embeddinggemma-2-Q8_0.gguf").path))
        XCTAssertEqual(scan().filter { $0.movability == .movable }.count, 2)
    }

    func testMoveRefusesWhenItCouldBreakSomething() throws {
        try makeDigUp()
        let mover = ModelMover(central: central)
        let original = digUpModels.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
        let model = try XCTUnwrap(scan().first { $0.url == original })

        // An app still downloading it.
        try makeFile(URL(fileURLWithPath: original.path + ".partial"))
        XCTAssertThrowsError(try mover.move(model)) { XCTAssertEqual($0 as? MoveError, .downloading("DigUp")) }
        try FileManager.default.removeItem(atPath: original.path + ".partial")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "nothing moved")

        // Something already in the way.
        try makeFile(central.appendingPathComponent("DigUp/embeddinggemma-2-Q8_0.gguf"))
        XCTAssertThrowsError(try mover.move(model)) { XCTAssertEqual($0 as? MoveError, .alreadyThere) }
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: original.path))

        // A model another tool owns.
        var managed = model
        managed.movability = .managed("Ollama manages this model.")
        XCTAssertThrowsError(try mover.move(managed)) { XCTAssertEqual($0 as? MoveError, .notMovable("Ollama manages this model.")) }

        // The file vanished between scan and click.
        try FileManager.default.removeItem(at: central.appendingPathComponent("DigUp/embeddinggemma-2-Q8_0.gguf"))
        try FileManager.default.removeItem(at: original)
        XCTAssertThrowsError(try mover.move(model))
    }

    func testMovingBackWithoutKnowingTheOldPlaceDoesNothing() throws {
        let file = try makeGGUF(central.appendingPathComponent("Other/x.gguf"), megabytes: 2)
        let model = try XCTUnwrap(scan().first { $0.url == file })
        XCTAssertEqual(model.movability, .central)
        XCTAssertThrowsError(try ModelMover(central: central).moveBack(model)) { XCTAssertEqual($0 as? MoveError, .noOriginalPlace) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Apps

    private func makeApp(_ name: String, in folder: URL, bundleID: String, embedded: [String] = []) throws {
        let contents = folder.appendingPathComponent("\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        for item in embedded { try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources/\(item)"), withIntermediateDirectories: true) }
    }

    func testWorksOutWhichAppAModelBelongsTo() throws {
        let apps = home.appendingPathComponent("Applications")
        try makeApp("DigUp", in: apps, bundleID: "com.abdurrahim.DigUp")
        try makeApp("superwhisper", in: apps, bundleID: "com.superduper.superwhisper", embedded: ["FluidAudio_FluidAudio.bundle"])
        try makeApp("Google Chrome", in: apps, bundleID: "com.google.Chrome")
        let index = AppIndex.build(home: home, folders: [apps])

        XCTAssertEqual(index.apps(forOwner: "DigUp").map(\.name), ["DigUp"])
        XCTAssertEqual(index.apps(forOwner: "DigUp").first?.bundleURL?.resolvingSymlinksInPath().path, apps.appendingPathComponent("DigUp.app").resolvingSymlinksInPath().path)
        XCTAssertEqual(index.apps(forOwner: "Google Chrome").map(\.name), ["Google Chrome"])
        XCTAssertEqual(index.apps(forOwner: "com.abdurrahim.DigUp").map(\.name), ["DigUp"], "a bundle-id folder name")
        XCTAssertEqual(index.apps(forOwner: "FluidAudio").map(\.name), ["superwhisper"], "an SDK built into an app")
        let unknown = index.apps(forOwner: "Hugging Face")
        XCTAssertEqual(unknown.map(\.name), ["Hugging Face"], "named, even when no app is installed")
        XCTAssertNil(unknown.first?.bundleURL)
        XCTAssertNotNil(unknown.first?.note)
        XCTAssertEqual(index.apps(forOwner: "Apple Visual Intelligence Core").first?.isMacOS, true, "gets the Apple logo")
        XCTAssertEqual(unknown.first?.isMacOS, false)
        XCTAssertEqual(index.apps(forOwner: "").count, 0)
        XCTAssertEqual(index.apps(forOwner: "DigUpTrial").map(\.name), ["DigUpTrial"], "a folder that merely starts with an app's name is not that app")
        XCTAssertNil(index.apps(forOwner: "DigUpTrial").first?.bundleURL)
    }

    func testRunningProgramsAreMatchedToTheirApp() throws {
        let apps = home.appendingPathComponent("Applications")
        try makeApp("DigUp", in: apps, bundleID: "x")
        let index = AppIndex.build(home: home, folders: [apps])
        let helper = apps.appendingPathComponent("DigUp.app/Contents/Helpers/Updater.app/Contents/MacOS/Updater").path
        XCTAssertEqual(index.app(forExecutable: helper, fallbackName: "Updater").name, "DigUp", "the app, not the helper nested in it")
        XCTAssertEqual(index.app(forExecutable: helper, fallbackName: "Updater").bundleURL?.lastPathComponent, "DigUp.app")
        let cli = index.app(forExecutable: "/opt/homebrew/bin/ollama", fallbackName: "ollama")
        XCTAssertEqual([cli.name, cli.inUse.description], ["ollama", "true"])
        XCTAssertNil(cli.bundleURL)

        let output = "p4242\ncDigUp\nf12\nn/tmp/a.gguf\np4243\ncpython\nf4\nn/tmp/a.gguf\nn/tmp/b.gguf\n"
        let users = ModelAssociations.parse(lsof: output, index: index)
        XCTAssertEqual(users["/tmp/a.gguf"]?.count, 2, "two programs have the first file open")
        XCTAssertEqual(users["/tmp/b.gguf"]?.count, 1)
    }

    func testAnAppsModelGetsItsAppAttachedWhenScanned() async throws {
        let apps = home.appendingPathComponent("Applications")
        try makeApp("DigUp", in: apps, bundleID: "com.abdurrahim.DigUp")
        try makeDigUp()
        let withApps = await ModelAssociations.apply(to: scan(), index: AppIndex.build(home: home, folders: [apps]))
        XCTAssertEqual(withApps.count, 2)
        for model in withApps { XCTAssertEqual(model.apps.map(\.name), ["DigUp"]) }
    }

    // MARK: Words

    func testNameMatchingOnlyLooksAtWholeWords() {
        XCTAssertTrue(ModelKnowledge.mentions("whisper-large-v3", "whisper"))
        XCTAssertTrue(ModelKnowledge.mentions("clip-vit-b32", "clip"))
        XCTAssertFalse(ModelKnowledge.mentions("clipboard history", "clip"))
        XCTAssertFalse(ModelKnowledge.mentions("my bookmarks", "bark"))
        XCTAssertEqual(ModelKnowledge.quantization(in: "Llama-3.1-8B-Instruct-Q4_K_M"), "Q4_K_M")
        XCTAssertEqual(ModelKnowledge.quantization(in: "model-f16"), "F16")
        XCTAssertNil(ModelKnowledge.quantization(in: "whisper-large-v3"))
        XCTAssertEqual(ModelKnowledge.displayName("Meta-Llama-3.1-8B-Instruct-Q4_K_M", nil), "Meta Llama 3.1 8B Instruct")
    }

    func testDescriptionsForCommonModels() {
        func describe(_ label: String, format: String = "GGUF") -> ModelKnowledge.Description {
            ModelKnowledge.describe(label: label, path: label, format: format, owner: nil, gguf: nil)
        }
        XCTAssertEqual(describe("ggml-large-v3-turbo", format: "GGML").kind, .speech)
        XCTAssertEqual(describe("whisper-small").kind, .speech)
        XCTAssertEqual(describe("Qwen2.5-7B-Instruct-Q4_K_M").kind, .language)
        XCTAssertEqual(describe("bge-small-en-v1.5", format: "ONNX").kind, .embedding)
        XCTAssertEqual(describe("stable-diffusion-xl", format: "Safetensors").kind, .imageGeneration)
        XCTAssertEqual(describe("yolov8n", format: "ONNX").kind, .vision)
        let unknown = describe("zzz-custom", format: "ONNX")
        XCTAssertEqual(unknown.kind, .other)
        XCTAssertTrue(unknown.summary.contains("ONNX"))
    }

    func testOwnerNamesFromFolders() {
        XCTAssertEqual(ModelScanner.ownerName(app: "Google", folder: "Chrome"), "Google Chrome")
        XCTAssertEqual(ModelScanner.ownerName(app: "com.apple.VisualIntelligenceCore", folder: nil), "Apple Visual Intelligence Core")
        XCTAssertEqual(ModelScanner.ownerName(app: "DigUp", folder: nil), "DigUp")
    }

    // MARK: Staying up to date

    func testWhichFileChangesAreWorthALook() {
        let c = "/Users/x/Library/Application Support/Toolbox/AI Models"
        XCTAssertTrue(ModelLibrary.isRelevant("/Users/x/Library/Application Support/DigUp/Models/a.gguf", central: c))
        XCTAssertTrue(ModelLibrary.isRelevant("\(c)/DigUp/a.gguf", central: c))
        XCTAssertTrue(ModelLibrary.isRelevant("/Users/x/.cache/huggingface/hub/models--a--b/blobs/x", central: c))
        XCTAssertTrue(ModelLibrary.isRelevant("/Users/x/Downloads/thing.safetensors", central: c))
        XCTAssertFalse(ModelLibrary.isRelevant("/Users/x/Library/Application Support/Slack/Cache/data_1", central: c))
        XCTAssertFalse(ModelLibrary.isRelevant("/Users/x/Documents/notes.txt", central: c))
    }

    @MainActor func testTheFileWatcherReportsCreationsAndRemovals() async throws {
        let folder = home.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let seen = Counter()
        let watcher = FileWatcher(paths: [folder.path], latency: 0.2) { paths in seen.add(paths) }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(500))

        let file = folder.appendingPathComponent("new.gguf")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        try await waitUntil { seen.paths.contains { $0.hasSuffix("new.gguf") } }

        let before = seen.paths.count
        try FileManager.default.removeItem(at: file)
        try await waitUntil { seen.paths.count > before }
    }

    @MainActor func testThePageLearnsAboutAddedAndRemovedModelsByItself() async throws {
        try makeDigUp()
        let library = ModelLibrary(home: home, spotlight: false)
        library.start()
        defer { library.stop() }
        try await waitUntil { library.hasScanned && library.models.count == 2 }

        // A model is downloaded into an app's folder...
        try makeGGUF(support.appendingPathComponent("LM Studio/models/Qwen2.5-7B-Instruct-Q4_K_M.gguf"), arch: "qwen2", megabytes: 4)
        try await waitUntil(seconds: 15) { library.models.count == 3 }
        XCTAssertTrue(library.models.contains { $0.name == "Qwen2.5 7B Instruct" || $0.owner == "LM Studio" })
        XCTAssertTrue(library.changeNote?.hasPrefix("Added") == true, "\(library.changeNote ?? "nil")")

        // ...and one is deleted.
        try FileManager.default.removeItem(at: digUpModels.appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf"))
        try await waitUntil(seconds: 15) { library.models.count == 2 }
        XCTAssertTrue(library.changeNote?.contains("Removed") == true, "\(library.changeNote ?? "nil")")
        XCTAssertFalse(library.models.contains { $0.name.contains("images and audio") })
    }

    @MainActor func testMovingThroughTheLibraryShowsInTheListWithoutAnyExtraStep() async throws {
        try makeDigUp()
        let library = ModelLibrary(home: home, spotlight: false)
        library.start()
        defer { library.stop() }
        try await waitUntil { library.models.count == 2 }
        let model = try XCTUnwrap(library.models.first { $0.name == "EmbeddingGemma 2 (text)" })

        try ModelMover(central: library.central).move(model)

        try await waitUntil(seconds: 15) { library.models.first { $0.name == "EmbeddingGemma 2 (text)" }?.movability == .central }
        XCTAssertEqual(library.models.count, 2)
    }

    // MARK: Helpers

    /// Size of the file a path leads to, links followed, read fresh every time.
    private func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return all }
        func add(_ new: [String]) { lock.lock(); all += new; lock.unlock() }
    }

    @MainActor private func waitUntil(seconds: Double = 8, _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

final class AIModelsWordingTests: XCTestCase {
    func testParameterCountsReadAsParametersNotSize() {
        var info = GGUFInfo(); info.architecture = "llama"; info.sizeLabel = "7B"
        let d = ModelKnowledge.describe(label: "model-Q4_K_M", path: "model-q4_k_m", format: "GGUF", owner: nil, gguf: info)
        XCTAssertTrue(d.tags.contains("7B parameters"), "\(d.tags)")
    }

    func testAppleModelsAreLeftToMacOS() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("apple-models-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundle = home.appendingPathComponent("Library/Caches/com.apple.VisualIntelligenceCore/e5-models/visualgrounding_md10_v1.mlmodelc/weights.bin")
        try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bundle.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bundle)
        try handle.truncate(atOffset: 3 << 20)
        try handle.close()
        let model = try XCTUnwrap(ModelScanner(home: home, central: home.appendingPathComponent("central")).scan().first)
        XCTAssertEqual(model.name, "Visual grounding (Apple)")
        XCTAssertEqual(model.owner, "Apple Visual Intelligence Core")
        XCTAssertEqual(model.movability, .managed("macOS manages this model and may update or remove it."))
    }
}
