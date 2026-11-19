import Foundation

/// Whoever waits for a vault item to reach the search index. Each wait is answered exactly once: by the index, by its own
/// time limit, or when search stops.
@MainActor
final class VaultSearchWaiters {
    private var waiting: [VaultItem.ID: [UUID: CheckedContinuation<Bool, Never>]] = [:]

    var count: Int { waiting.values.reduce(0) { $0 + $1.count } }

    /// `start` runs once the wait is registered, so an index pass it kicks off can never answer before the wait exists.
    func wait(for id: VaultItem.ID, atMost limit: Duration, start: () -> Void) async -> Bool {
        await withCheckedContinuation { waiter in
            let token = UUID()
            waiting[id, default: [:]][token] = waiter
            start()
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                self?.waiting[id]?.removeValue(forKey: token)?.resume(returning: false)
            }
        }
    }

    func answer(_ id: VaultItem.ID, searchable: Bool) {
        waiting.removeValue(forKey: id)?.values.forEach { $0.resume(returning: searchable) }
    }

    func answerAll(searchable: Bool) {
        let all = waiting
        waiting = [:]
        all.values.flatMap(\.values).forEach { $0.resume(returning: searchable) }
    }

    /// Answers everyone waiting now from `decide`; anyone who starts waiting meanwhile is left for the next pass.
    func answerEach(_ decide: (VaultItem.ID) async -> Bool) async {
        let all = waiting
        waiting = [:]
        for (id, waiters) in all {
            let searchable = await decide(id)
            waiters.values.forEach { $0.resume(returning: searchable) }
        }
    }

    func carry(from old: VaultItem.ID, to new: VaultItem.ID) {
        guard let moving = waiting.removeValue(forKey: old) else { return }
        waiting[new, default: [:]].merge(moving) { kept, _ in kept }
    }
}
