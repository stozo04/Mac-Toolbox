import AppKit
import XCTest
@testable import Toolbox

@MainActor
final class QuitPreparationTests: XCTestCase {
    func testWithNothingToPrepareTheAppQuitsAtOnce() {
        let preparation = QuitPreparation()
        preparation.add(patience: .seconds(60)) { nil }
        var quit = false

        XCTAssertEqual(preparation.terminateReply { _ in quit = true }, .terminateNow)
        XCTAssertEqual(QuitPreparation().terminateReply { _ in quit = true }, .terminateNow)
        XCTAssertFalse(quit)
    }

    func testQuitWaitsForItsPreparations() async throws {
        let (held, release) = AsyncStream<Void>.makeStream()
        addTeardownBlock { release.finish() }
        let preparation = QuitPreparation()
        var prepared = false
        var quitAfterPreparing: Bool?
        preparation.add(patience: .milliseconds(1)) { Task { true } }
        preparation.add(patience: .seconds(60)) {
            Task {
                for await _ in held {}
                prepared = true
                return true
            }
        }

        let reply = preparation.terminateReply { mayQuit in quitAfterPreparing = mayQuit && prepared }

        XCTAssertEqual(reply, .terminateLater)
        try await pause(for: .milliseconds(50), because: "a quit that didn't wait would have gone ahead by now")
        XCTAssertNil(quitAfterPreparing)
        release.finish()
        try await waitUntil("the app was told to quit") { quitAfterPreparing != nil }
        XCTAssertEqual(quitAfterPreparing, true)
    }

    func testQuitGoesAheadWhenAPreparationOutlastsItsPatience() async throws {
        let (held, release) = AsyncStream<Void>.makeStream()
        addTeardownBlock { release.finish() }
        let preparation = QuitPreparation()
        preparation.add(patience: .seconds(60)) { nil }
        preparation.add(patience: .milliseconds(50)) {
            Task {
                for await _ in held {}
                return true
            }
        }
        var quit = false

        let reply = preparation.terminateReply { mayQuit in quit = mayQuit }

        XCTAssertEqual(reply, .terminateLater)
        try await waitUntil("the app stopped waiting and quit") { quit }
    }

    func testAPreparationThatFailsCancelsTheQuit() async throws {
        let preparation = QuitPreparation()
        preparation.add(patience: .seconds(60)) { Task { true } }
        preparation.add(patience: .seconds(60)) { Task { false } }
        var answer: Bool?

        XCTAssertEqual(preparation.terminateReply { answer = $0 }, .terminateLater)

        try await waitUntil("the quit was answered") { answer != nil }
        XCTAssertEqual(answer, false)
    }

    func testAPreparationThatOutlastsItsPatienceCanStillCancelTheQuit() async throws {
        let (held, release) = AsyncStream<Void>.makeStream()
        addTeardownBlock { release.finish() }
        let preparation = QuitPreparation()
        preparation.add(patience: .milliseconds(50), mayQuitUnfinished: { false }, {
            Task {
                for await _ in held {}
                return true
            }
        })
        var answer: Bool?

        XCTAssertEqual(preparation.terminateReply { answer = $0 }, .terminateLater)

        try await waitUntil("the quit was answered") { answer != nil }
        XCTAssertEqual(answer, false)
    }

    func testTheAppDelegateQuitsAtOnceWhenNothingIsOpen() {
        let delegate = MainWindowReopener()
        delegate.quitPreparation = QuitPreparation()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }
}
