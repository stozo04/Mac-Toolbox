import XCTest
@testable import Toolbox

@MainActor
final class FileDropTests: XCTestCase {
    private typealias Finish = @Sendable (URL?) -> Void

    private var dir: URL!
    private let finishers = Locked<[Finish]>([])
    private let deliveries = Locked<[[URL]]>([])

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-drop-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func drop(_ count: Int, deliver: (@MainActor ([URL]) -> Void)? = nil) {
        let loader: FileDrop.Loader = { [finishers] finish in finishers.update { $0.append(finish) } }
        FileDrop.collect(from: Array(repeating: loader, count: count)) { [deliveries] urls in
            deliveries.update { $0.append(urls) }
            deliver?(urls)
        }
    }

    private func finish(_ index: Int, with url: URL?) throws {
        try finishers.value.element(at: index)(url)
    }

    private func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func testEveryLoadStartsBeforeTheDropReturns() {
        drop(3)

        XCTAssertEqual(finishers.value.count, 3)
        XCTAssertEqual(deliveries.value, [])
    }

    func testFilesArriveOnceInTheOrderTheyWereDroppedHoweverTheyLoad() async throws {
        let (a, b, c) = (file("a.mov"), file("b.mov"), file("c.mov"))
        drop(3)

        try finish(2, with: c)
        try finish(0, with: a)
        XCTAssertEqual(deliveries.value, [], "nothing is delivered while a file is still loading")
        try finish(1, with: b)

        try await waitUntil("the drop is delivered") { !deliveries.value.isEmpty }
        try await pause(for: .milliseconds(50), because: "a second delivery would arrive on a later main-actor turn")
        XCTAssertEqual(deliveries.value, [[a, b, c]])
    }

    func testAFileThatFailsToLoadIsLeftOutAndTheRestStillArrive() async throws {
        let (a, c) = (file("a.mov"), file("c.mov"))
        drop(3)

        try finish(0, with: a)
        try finish(1, with: nil)
        try finish(2, with: c)

        try await waitUntil("the drop is delivered") { !deliveries.value.isEmpty }
        XCTAssertEqual(deliveries.value, [[a, c]])
    }

    func testADropWhereNothingLoadsIsNotDelivered() async throws {
        drop(2)

        try finish(0, with: nil)
        try finish(1, with: nil)

        try await pause(for: .milliseconds(50), because: "a delivery would arrive on a later main-actor turn")
        XCTAssertEqual(deliveries.value, [])
    }

    func testALoadReportedTwiceDoesNotDeliverEarlyOrTwice() async throws {
        let (a, b) = (file("a.mov"), file("b.mov"))
        drop(2)

        try finish(0, with: a)
        try finish(0, with: a)
        try await pause(for: .milliseconds(50), because: "an early delivery would arrive on a later main-actor turn")
        XCTAssertEqual(deliveries.value, [])
        try finish(1, with: b)
        try finish(1, with: b)

        try await waitUntil("the drop is delivered") { !deliveries.value.isEmpty }
        try await pause(for: .milliseconds(50), because: "a second delivery would arrive on a later main-actor turn")
        XCTAssertEqual(deliveries.value, [[a, b]])
    }

    func testDroppingATextFileAndAVideoTogetherReportsTheSkippedFileWhicheverLoadsFirst() async throws {
        let notes = file("notes.txt"), clip = file("clip.mov")
        try Data("hello".utf8).write(to: notes)
        try Data().write(to: clip)

        for loadOrder in [[0, 1], [1, 0]] {
            let model = MuteVideoModel()
            finishers.set([])
            deliveries.set([])
            drop(2) { model.add($0) }

            for index in loadOrder { try finish(index, with: try [notes, clip].element(at: index)) }

            try await waitUntil("the drop reaches the queue") { !deliveries.value.isEmpty }
            XCTAssertEqual(model.items.map(\.url), [clip], "load order \(loadOrder)")
            XCTAssertEqual(model.notice, "1 item(s) had no videos and were skipped.", "load order \(loadOrder)")
        }
    }
}
