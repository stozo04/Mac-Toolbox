import XCTest
@testable import Toolbox

@MainActor
final class VaultSearchWaitersTests: XCTestCase {
    private let long = Duration.seconds(60)

    private func startWaiting(_ waiters: VaultSearchWaiters, for id: String, atMost limit: Duration) async throws -> Task<Bool, Never> {
        let before = waiters.count
        let waiting = Task { await waiters.wait(for: id, atMost: limit) {} }
        try await waitUntil("the wait is registered") { waiters.count == before + 1 }
        return waiting
    }

    func testTheIndexAnswersEveryoneWaitingForThatItem() async throws {
        let waiters = VaultSearchWaiters()
        let first = try await startWaiting(waiters, for: "a", atMost: long)
        let second = try await startWaiting(waiters, for: "a", atMost: long)
        let other = try await startWaiting(waiters, for: "b", atMost: long)

        waiters.answer("a", searchable: true)

        let answers = (await first.value, await second.value)
        XCTAssertTrue(answers.0)
        XCTAssertTrue(answers.1)
        XCTAssertEqual(waiters.count, 1, "the wait for another item was answered too")
        waiters.answer("b", searchable: false)
        let otherAnswer = await other.value
        XCTAssertFalse(otherAnswer)
    }

    func testAWaitThatRunsOutIsAnsweredOnceAndALateAnswerIsHarmless() async throws {
        let waiters = VaultSearchWaiters()
        let waiting = try await startWaiting(waiters, for: "a", atMost: .milliseconds(10))

        let answer = await waiting.value
        waiters.answer("a", searchable: true)

        XCTAssertFalse(answer)
        XCTAssertEqual(waiters.count, 0)
    }

    func testStoppingSearchAnswersEveryoneNotSearchable() async throws {
        let waiters = VaultSearchWaiters()
        let first = try await startWaiting(waiters, for: "a", atMost: long)
        let second = try await startWaiting(waiters, for: "b", atMost: long)

        waiters.answerAll(searchable: false)

        let answers = (await first.value, await second.value)
        XCTAssertFalse(answers.0)
        XCTAssertFalse(answers.1)
        XCTAssertEqual(waiters.count, 0)
    }

    func testARenamedItemKeepsItsWait() async throws {
        let waiters = VaultSearchWaiters()
        let waiting = try await startWaiting(waiters, for: "old.mov", atMost: long)

        waiters.carry(from: "old.mov", to: "new.mov")
        waiters.answer("old.mov", searchable: false)
        XCTAssertEqual(waiters.count, 1, "an answer for the old name reached the renamed item's wait")
        waiters.answer("new.mov", searchable: true)

        let answer = await waiting.value
        XCTAssertTrue(answer)
    }

    func testARenamedItemsWaitStillRunsOut() async throws {
        let waiters = VaultSearchWaiters()
        let waiting = try await startWaiting(waiters, for: "old.mov", atMost: .milliseconds(50))

        waiters.carry(from: "old.mov", to: "new.mov")

        let answer = await waiting.value
        XCTAssertFalse(answer)
        XCTAssertEqual(waiters.count, 0)
    }

    func testAnsweringFromTheIndexLeavesAWaitThatStartsMeanwhileForTheNextPass() async throws {
        let waiters = VaultSearchWaiters()
        let early = try await startWaiting(waiters, for: "a", atMost: long)
        var late: Task<Bool, Never>?

        await waiters.answerEach { _ in
            late = Task { await waiters.wait(for: "b", atMost: self.long) {} }
            try? await waitUntil("the late wait is registered") { waiters.count == 1 }
            return true
        }

        let earlyAnswer = await early.value
        XCTAssertTrue(earlyAnswer)
        XCTAssertEqual(waiters.count, 1)
        waiters.answerAll(searchable: false)
        let lateAnswer = await late?.value
        XCTAssertEqual(lateAnswer, false)
    }

    func testWaitStartsItsWorkOnlyOnceTheWaitIsRegistered() async {
        let waiters = VaultSearchWaiters()

        let answer = await waiters.wait(for: "a", atMost: long) { waiters.answer("a", searchable: true) }

        XCTAssertTrue(answer)
    }
}
