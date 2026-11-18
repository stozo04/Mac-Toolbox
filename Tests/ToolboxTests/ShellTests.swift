import XCTest
@testable import Toolbox

final class ShellTests: XCTestCase {
    private static let ignoresSIGTERM = "trap '' TERM; echo $$; exec /bin/sleep 20"
    private static let printsItsPID = "echo $$; exec /bin/sleep 20"

    override func tearDown() { killProgramsLeftRunning() }

    private func spin(microseconds: Int) {
        let end = DispatchTime.now().uptimeNanoseconds + UInt64(microseconds) * 1000
        while DispatchTime.now().uptimeNanoseconds < end {}
    }

    private func start(_ script: String, timeout: Shell.Timeout) async throws -> (run: Task<Shell.Result, Error>, pid: Int32) {
        let child = Locked<Int32?>(nil)
        killAfterTest(child)
        let run = Task.detached {
            try await Shell.run("/bin/sh", ["-c", script], timeout: timeout) { text in
                if let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { child.set(pid) }
            }
        }
        try await waitUntil("the program has printed its process number") { child.value != nil }
        return (run, try XCTUnwrap(child.value))
    }

    private func assertCancelled(_ result: Result<Shell.Result, Error>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else { return XCTFail("the run returned a result instead of throwing", file: file, line: line) }
        XCTAssertTrue(error is CancellationError, "threw \(error)", file: file, line: line)
    }

    // MARK: Cancelling

    func testATaskCancelledBeforeItStartsNeverRunsTheProgram() async {
        let started = Date()
        let run = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Shell.run("/bin/sleep", ["5"], timeout: .untilCancelled)
        }
        assertCancelled(await run.result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testCancellingJustAfterStartAlwaysStopsTheProgram() async {
        let attempts = 240
        let batch = 8
        let longestDelay = 3000
        var late: [Int] = []
        var notCancelled = 0
        for first in stride(from: 0, to: attempts, by: batch) {
            let outcomes = await withTaskGroup(of: (delay: Int, seconds: Double, cancelled: Bool).self) { group in
                for index in first..<min(first + batch, attempts) {
                    let delay = index * longestDelay / attempts
                    group.addTask { [spin] in
                        let run = Task.detached { try await Shell.run("/bin/sleep", ["5"], timeout: .untilCancelled) }
                        spin(delay)
                        let cancelled = Date()
                        run.cancel()
                        let result = await run.result
                        if case .failure(let error) = result { return (delay, Date().timeIntervalSince(cancelled), error is CancellationError) }
                        return (delay, Date().timeIntervalSince(cancelled), false)
                    }
                }
                var outcomes: [(delay: Int, seconds: Double, cancelled: Bool)] = []
                for await outcome in group { outcomes.append(outcome) }
                return outcomes
            }
            late += outcomes.filter { $0.seconds > 1 }.map(\.delay)
            notCancelled += outcomes.filter { !$0.cancelled }.count
        }
        XCTAssertTrue(late.isEmpty, "\(late.count) of \(attempts) cancelled runs kept going for more than 1 s after the cancel; cancel delays in microseconds: \(late.sorted())")
        XCTAssertEqual(notCancelled, 0, "cancelled runs that did not throw CancellationError")
    }

    func testCancellingAProgramThatIgnoresSIGTERMKillsIt() async throws {
        let (run, pid) = try await start(Self.ignoresSIGTERM, timeout: .untilCancelled)
        let cancelled = Date()
        run.cancel()
        assertCancelled(await run.result)
        XCTAssertFalse(isRunning(pid))
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), Shell.secondsFromTerminateToKill + 3)
    }

    // MARK: Timeouts

    func testATimeoutStopsAProgramThatIgnoresSIGTERM() async throws {
        let (run, pid) = try await start(Self.ignoresSIGTERM, timeout: .seconds(0.5))
        let result = await run.result
        guard case .failure(let error) = result else { return XCTFail("the run returned a result instead of timing out") }
        XCTAssertEqual(error as? Shell.ShellError, .timedOut("/bin/sh", 0.5))
        XCTAssertFalse(isRunning(pid))
    }

    func testATimeoutIsToldApartFromAProgramThatExitsWithTheSameStatus() async throws {
        let ordinary = try await Shell.run("/bin/sh", ["-c", "exit 15"], timeout: .quick)
        XCTAssertEqual(ordinary.status, SIGTERM)
        do {
            _ = try await Shell.run("/bin/sleep", ["20"], timeout: .seconds(1))
            XCTFail("a timed out sleep returned a result")
        } catch {
            XCTAssertEqual(error as? Shell.ShellError, .timedOut("/bin/sleep", 1))
            XCTAssertEqual(error.localizedDescription, "sleep did not finish within 1 seconds, so it was stopped.")
        }
    }

    func testAProgramThatEndsBeforeItsTimeoutReturnsItsResult() async throws {
        let result = try await Shell.run("/bin/echo", ["done"], timeout: .seconds(1))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.out, "done\n")
    }

    // MARK: Quitting

    func testQuittingStopsOnlyTheProgramsThatRunUntilCancelled() async throws {
        let (polite, politePID) = try await start(Self.printsItsPID, timeout: .untilCancelled)
        let (stubborn, stubbornPID) = try await start(Self.ignoresSIGTERM, timeout: .untilCancelled)
        let (bounded, boundedPID) = try await start(Self.printsItsPID, timeout: .seconds(20))

        Shell.stopChildrenBeforeQuit(grace: 0.3)

        assertCancelled(await polite.result)
        assertCancelled(await stubborn.result)
        XCTAssertFalse(isRunning(politePID))
        XCTAssertFalse(isRunning(stubbornPID))
        XCTAssertTrue(isRunning(boundedPID), "a program with a timeout ends by itself and is left to finish")
        bounded.cancel()
        assertCancelled(await bounded.result)
    }

    // MARK: Output

    func testAllOutputOfAFinishedProgramIsReturned() async throws {
        let runs = 300
        let batch = 12
        let expected = (1...200_000).map(String.init).joined(separator: "\n") + "\n"
        var wrong = 0
        for first in stride(from: 0, to: runs, by: batch) {
            wrong += await withTaskGroup(of: String?.self) { group in
                for _ in first..<min(first + batch, runs) {
                    group.addTask { try? await Shell.run("/usr/bin/seq", ["1", "200000"], timeout: .quick).out }
                }
                var wrong = 0
                for await output in group where output != expected { wrong += 1 }
                return wrong
            }
        }
        XCTAssertEqual(wrong, 0, "outputs that were cut short, reordered or missing in \(runs) runs")
    }

    func testStreamedOutputIsCompleteAndNeverCutsACharacterInTwo() async throws {
        let pieces = Locked<[String]>([])
        let result = try await Shell.run("/bin/sh", ["-c", #"printf 'caf\303'; sleep 0.2; printf '\251\n'; printf 'end'"#], timeout: .quick) { piece in
            pieces.update { $0.append(piece) }
        }
        XCTAssertEqual(result.out, "café\nend")
        XCTAssertEqual(pieces.value.joined(), result.out)
        XCTAssertFalse(pieces.value.contains { $0.contains("\u{FFFD}") }, "\(pieces.value)")
    }
}
