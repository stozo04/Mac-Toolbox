import AppKit

@MainActor
final class QuitPreparation {
    static let shared = QuitPreparation()
    private var steps: [Step] = []

    private struct Step {
        let patience: Duration
        let mayQuitUnfinished: @MainActor () -> Bool
        let begin: @MainActor () -> Task<Bool, Never>?
    }

    func add(patience: Duration, mayQuitUnfinished: @escaping @MainActor () -> Bool = { true },
             _ step: @escaping @MainActor () -> Task<Bool, Never>?) {
        steps.append(Step(patience: patience, mayQuitUnfinished: mayQuitUnfinished, begin: step))
    }

    func terminateReply(reply: @escaping @MainActor (_ mayQuit: Bool) -> Void) -> NSApplication.TerminateReply {
        let begun = steps.compactMap { step in step.begin().map { (work: $0, step: step) } }
        guard let patience = begun.map(\.step.patience).max() else { return .terminateNow }
        Task {
            guard await Self.finished(begun.map(\.work), within: patience) else {
                Log.warning("Quit preparations did not finish", category: "app", ["waited": "\(patience)"])
                return reply(begun.map { $0.step.mayQuitUnfinished() }.allSatisfy { $0 })
            }
            var mayQuit = true
            for (work, _) in begun where await !work.value { mayQuit = false }
            reply(mayQuit)
        }
        return .terminateLater
    }

    static func finished<Answer: Sendable>(_ work: [Task<Answer, Never>], within patience: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            Task {
                for task in work { _ = await task.value }
                answer.give(true)
            }
            Task {
                try? await Task.sleep(for: patience)
                answer.give(false)
            }
        }
    }

    private final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        func give(_ answer: Bool) {
            let waiting = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: answer)
        }
    }
}
