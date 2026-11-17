import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&stored)
    }
}

private func waitUntil(seconds: Double, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
private func waitOnMainUntil(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func spin(microseconds: Int) {
    let end = DispatchTime.now().uptimeNanoseconds + UInt64(microseconds) * 1000
    while DispatchTime.now().uptimeNanoseconds < end {}
}

final class ReproShellTests: XCTestCase {
    func testControlATaskCancelledBeforeItStartsNeverRunsTheProgram() async {
        let started = Date()
        let run = Task.detached { () -> Result<Shell.Result, Error> in
            withUnsafeCurrentTask { $0?.cancel() }
            do { return .success(try await Shell.run("/bin/sleep", ["5"])) } catch { return .failure(error) }
        }
        let outcome = await run.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        if case .success = outcome { XCTFail("an already cancelled task still ran the program to the end") }
    }

    func testCancellingJustAfterStartAlwaysStopsTheProgram() async {
        let attempts = 240
        let batch = 8
        let longestDelay = 3000
        var late: [Int] = []
        for first in stride(from: 0, to: attempts, by: batch) {
            let slow = await withTaskGroup(of: (delay: Int, seconds: Double).self) { group -> [Int] in
                for index in first..<min(first + batch, attempts) {
                    let delay = index * longestDelay / attempts
                    group.addTask {
                        let run = Task.detached { try await Shell.run("/bin/sleep", ["5"]) }
                        spin(microseconds: delay)
                        let cancelled = Date()
                        run.cancel()
                        _ = await run.result
                        return (delay, Date().timeIntervalSince(cancelled))
                    }
                }
                var slow: [Int] = []
                for await result in group where result.seconds > 1 { slow.append(result.delay) }
                return slow
            }
            late += slow
        }
        XCTAssertTrue(late.isEmpty, "\(late.count) of \(attempts) cancelled runs kept going for more than 1 s after the cancel; cancel delays in microseconds: \(late.sorted())")
    }

    func testTimeoutStopsAProgramThatIgnoresSIGTERM() async {
        let child = Locked<Int32?>(nil)
        let finished = Locked(false)
        addTeardownBlock { if let pid = child.value { kill(pid, SIGKILL) } }
        let run = Task.detached {
            let result = try? await Shell.run("/bin/sh", ["-c", "trap '' TERM; echo $$; exec /bin/sleep 20"], timeout: 1) { text in
                if let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { child.set(pid) }
            }
            finished.set(true)
            return result
        }
        let returned = await waitUntil(seconds: 5) { finished.value }
        let stillAlive = child.value.map { kill($0, 0) == 0 } ?? false
        XCTAssertTrue(returned, "Shell.run(timeout: 1) had not returned after 5 s; child still alive: \(stillAlive)")
        if let pid = child.value { kill(pid, SIGKILL) }
        _ = await run.value
    }

    func testCallerCanTellATimeoutFromAnOrdinaryExit() async throws {
        let ordinary = try await Shell.run("/bin/sh", ["-c", "exit 15"])
        let timedOut: Shell.Result
        do { timedOut = try await Shell.run("/bin/sleep", ["20"], timeout: 1) } catch { return }
        let looksTheSame = timedOut.status == ordinary.status && timedOut.out == ordinary.out && timedOut.err == ordinary.err
        XCTAssertFalse(looksTheSame, "a timed out sleep returned status \(timedOut.status), out \"\(timedOut.out)\", err \"\(timedOut.err)\" without throwing: identical to a program that exits 15 by itself")
    }

    func testAllOutputOfAFinishedProgramIsReturned() async throws {
        let runs = 2000
        let batch = 12
        let expected = (1...200_000).map(String.init).joined(separator: "\n") + "\n"
        var truncated = 0
        var reordered = 0
        var failed = 0
        for first in stride(from: 0, to: runs, by: batch) {
            let outputs = await withTaskGroup(of: String?.self) { group -> [String?] in
                for _ in first..<min(first + batch, runs) {
                    group.addTask { try? await Shell.run("/usr/bin/seq", ["1", "200000"], timeout: 30).out }
                }
                var outputs: [String?] = []
                for await output in group { outputs.append(output) }
                return outputs
            }
            for output in outputs {
                guard let output else { failed += 1; continue }
                if output == expected { continue }
                if output.utf8.count < expected.utf8.count { truncated += 1 } else { reordered += 1 }
            }
        }
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(truncated + reordered, 0, "\(truncated) truncated and \(reordered) reordered outputs in \(runs) runs")
    }
}

final class ReproTaskCancellationProofs: XCTestCase {
    func testProofTaskIsCancelledIsFalseInACallbackOnAnotherQueue() async {
        let task = Task.detached { () -> (inTask: Bool, inCallback: Bool) in
            withUnsafeCurrentTask { $0?.cancel() }
            let inTask = Task.isCancelled
            let inCallback = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: Task.isCancelled) }
            }
            return (inTask, inCallback)
        }
        let seen = await task.value
        XCTAssertTrue(seen.inTask)
        XCTAssertFalse(seen.inCallback)
    }

    func testProofCancellingATaskDoesNotCancelADetachedTaskItAwaits() async {
        let outer = Task { () -> Bool in
            await Task.detached { () -> Bool in
                let deadline = Date().addingTimeInterval(0.3)
                while Date() < deadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return Task.isCancelled
            }.value
        }
        outer.cancel()
        let detachedSawTheCancel = await outer.value
        XCTAssertFalse(detachedSawTheCancel)
    }
}

@MainActor
final class ReproStaleResultTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("repro-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func solidImage(side: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try XCTUnwrap(context.makeImage())
    }

    private func writeImage(_ image: CGImage, to url: URL, type: UTType) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeColorPicker() throws -> ColorPickerModel {
        ColorPickerModel(defaults: try XCTUnwrap(UserDefaults(suiteName: "repro-process-\(UUID())")))
    }

    private func makeBigAndSmallImages() throws -> (big: URL, small: URL, bigReadSeconds: Double) {
        let big = dir.appendingPathComponent("big.jpg"), small = dir.appendingPathComponent("small.png")
        try writeImage(solidImage(side: 6000, red: 1, green: 0, blue: 0), to: big, type: .jpeg)
        try writeImage(solidImage(side: 8, red: 0, green: 0, blue: 1), to: small, type: .png)
        let started = Date()
        XCTAssertNotNil(PaletteExtractor.sample(at: big))
        return (big, small, Date().timeIntervalSince(started))
    }

    func testClearingThePaletteWhileAnImageIsReadKeepsItCleared() async throws {
        let images = try makeBigAndSmallImages()
        let model = try makeColorPicker()
        model.loadPalette(from: [images.big])
        model.clearPalette()
        let settled = await waitOnMainUntil(seconds: 30) { !model.isReadingImage }
        XCTAssertTrue(settled)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.paletteName, "the palette was cleared after the load began, but the late result came back")
        XCTAssertTrue(model.palette.isEmpty)
    }

    func testANewerPaletteImageIsNotReplacedByAnOlderSlowerOne() async throws {
        let images = try makeBigAndSmallImages()
        let rounds = 5
        var replaced = 0
        for _ in 0..<rounds {
            let model = try makeColorPicker()
            model.loadPalette(from: [images.big])
            model.loadPalette(from: [images.small])
            let newerShown = await waitOnMainUntil(seconds: 30) { model.paletteName == "small.png" }
            if !newerShown {
                XCTAssertEqual(model.paletteName, "big.jpg", "neither image arrived")
                replaced += 1
                continue
            }
            if await waitOnMainUntil(seconds: images.bigReadSeconds * 4 + 1, { model.paletteName == "big.jpg" }) { replaced += 1 }
        }
        XCTAssertEqual(replaced, 0, "the older image ended up shown in \(replaced) of \(rounds) rounds (reading it takes \(images.bigReadSeconds) s)")
    }

    func testAMeasurementStartedEarlierDoesNotReplaceANewerOne() async throws {
        let root = dir.appendingPathComponent("hog")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: root.appendingPathComponent("a"))
        let gate = FilterGate()
        let hog = SpaceHog(id: "repro", title: "Repro", detail: "", symbol: "folder", root: root, clearing: .trash) { _ in
            gate.pass()
            return true
        }
        let model = StorageExplorerModel(hogs: [hog], trash: { _ in }, delete: { _ in })
        let names = { model.result(hog)?.items.map(\.url.lastPathComponent).sorted() }

        model.measureAll()
        let measured = await waitOnMainUntil(seconds: 10) { names() == ["a"] }
        XCTAssertTrue(measured)

        model.open(hog)
        gate.arm()
        model.clearSelected()
        let held = await waitOnMainUntil(seconds: 10) { gate.isHolding }
        XCTAssertTrue(held, "the measurement after clearing never reached the gate")

        try Data(repeating: 1, count: 2000).write(to: root.appendingPathComponent("b"))
        model.measureAll()
        let newerArrived = await waitOnMainUntil(seconds: 10) { names() == ["a", "b"] }
        XCTAssertTrue(newerArrived, "the newer measurement did not arrive, got \(String(describing: names()))")

        gate.release()
        let olderLanded = await waitOnMainUntil(seconds: 2) { names() != ["a", "b"] }
        XCTAssertFalse(olderLanded, "the measurement that started before file b existed replaced the newer one: \(String(describing: names()))")
    }
}

private final class FilterGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var holding = false
    private let semaphore = DispatchSemaphore(value: 0)

    var isHolding: Bool {
        lock.lock(); defer { lock.unlock() }
        return holding
    }

    func arm() {
        lock.lock(); defer { lock.unlock() }
        armed = true
    }

    func pass() {
        lock.lock()
        let hold = armed
        armed = false
        if hold { holding = true }
        lock.unlock()
        if hold { _ = semaphore.wait(timeout: .now() + 20) }
    }

    func release() { semaphore.signal() }
}

final class ReproBlurCacheTests: XCTestCase {
    private func solidImage(red: CGFloat, blue: CGFloat) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()
    }

    private func centerPixel(of image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return bytes
    }

    private func primeWithARedImage(_ cache: AnnotateBlurCache) -> ObjectIdentifier? {
        autoreleasepool {
            guard let red = solidImage(red: 1, blue: 0) else { return nil }
            _ = cache.image(for: red, style: .pixelate, amount: 4, unit: 1)
            return ObjectIdentifier(red)
        }
    }

    func testANewImageAtTheAddressOfTheOldOneGetsItsOwnBlur() throws {
        let cache = AnnotateBlurCache()
        let freed = try XCTUnwrap(primeWithARedImage(cache))
        var attempts = 0
        var pixels: (cached: [UInt8], fresh: [UInt8])?
        for _ in 0..<200 where pixels == nil {
            var held: [CGImage] = []
            for _ in 0..<100 where pixels == nil {
                attempts += 1
                try autoreleasepool {
                    let blue = try XCTUnwrap(solidImage(red: 0, blue: 1))
                    held.append(blue)
                    guard ObjectIdentifier(blue) == freed else { return }
                    let cached = try XCTUnwrap(cache.image(for: blue, style: .pixelate, amount: 4, unit: 1))
                    let fresh = try XCTUnwrap(AnnotateBlurCache().image(for: blue, style: .pixelate, amount: 4, unit: 1))
                    pixels = (try XCTUnwrap(centerPixel(of: cached)), try XCTUnwrap(centerPixel(of: fresh)))
                }
            }
        }
        guard let pixels else { throw XCTSkip("no new image reused the freed image's address in \(attempts) allocations") }
        XCTAssertEqual(pixels.cached, pixels.fresh, "address reused after \(attempts) allocations: the cache returned the blur of the freed red image for a blue one")
    }
}

private final class HeldRequest: URLProtocol, @unchecked Sendable {
    static let held = Locked<[HeldRequest]>([])

    private(set) var messages: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let rows = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] ?? []
        messages = rows.compactMap { $0["message"] as? String }
        Self.held.update { $0.append(self) }
    }

    override func stopLoading() {}

    func respond(status: Int) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

final class ReproLogSinkTests: XCTestCase {
    override func setUp() { HeldRequest.held.set([]) }

    override func tearDown() {
        HeldRequest.held.value.forEach { $0.respond(status: 201) }
        HeldRequest.held.set([])
    }

    private func makeSink() throws -> SupabaseLogSink {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldRequest.self]
        let url = try XCTUnwrap(URL(string: "https://repro.invalid"))
        return SupabaseLogSink(config: SupabaseLogConfig(url: url, key: "test"), flushInterval: 3600,
                               session: URLSession(configuration: configuration))
    }

    private func write(_ range: Range<Int>, to sink: SupabaseLogSink) {
        for index in range {
            sink.write(LogEvent(timestamp: Date(timeIntervalSince1970: 0), level: .warning, category: "repro", message: String(index),
                                metadata: [:], appVersion: "1", osVersion: "os", installID: "i", sessionID: "s"))
        }
    }

    private func secondRequestMessages(queuedFirst: Int, writtenDuringSend: Int) async throws -> [String]? {
        let sink = try makeSink()
        write(0..<queuedFirst, to: sink)
        sink.flush()
        let sending = await waitUntil(seconds: 10) { HeldRequest.held.value.count == 1 }
        XCTAssertTrue(sending, "the first batch never reached the transport")
        let first = try XCTUnwrap(HeldRequest.held.value.first)
        XCTAssertEqual(first.messages.count, queuedFirst)
        write(queuedFirst..<queuedFirst + writtenDuringSend, to: sink)
        first.respond(status: 201)
        let sentAgain = await waitUntil(seconds: 3) {
            sink.flush()
            return HeldRequest.held.value.count >= 2
        }
        return sentAgain ? HeldRequest.held.value.last?.messages : nil
    }

    func testControlEventsWrittenDuringASendGoOutInTheNextBatch() async throws {
        let messages = try await secondRequestMessages(queuedFirst: 10, writtenDuringSend: 5)
        XCTAssertEqual(messages, (10..<15).map(String.init))
    }

    func testEventsWrittenWhileAFullQueueIsBeingSentAreNotDropped() async throws {
        let messages = try await secondRequestMessages(queuedFirst: 500, writtenDuringSend: 100)
        XCTAssertEqual(messages, (500..<600).map(String.init), "100 events written during the send were never sent")
    }
}
