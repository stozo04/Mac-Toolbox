import AVFoundation
import Foundation

/// The comparison screen's state: the set of copies on screen, which ones are ticked to keep, and the one "do the same"
/// box. The add and the Duplicates view ask it for a choice and carry the choice out themselves.
@MainActor
@Observable
final class VaultComparison {
    enum Origin: Equatable { case adding, downloads, vault }

    struct Copy: Identifiable, Equatable {
        enum Place: Equatable {
            case vault
            /// Not in the vault yet: a file being added.
            case incoming
            /// Put in the vault by Download Video, which had no one to ask.
            case downloaded
        }

        let item: VaultItem
        let place: Place
        var id: VaultItem.ID { item.id }
        var isIncoming: Bool { place == .incoming }
        var isNew: Bool { place != .vault }
    }

    struct Group: Equatable {
        let copies: [Copy]
        let match: VaultDuplicates.Match
        var kind: VaultItem.Kind { copies.first?.item.kind ?? .video }
    }

    enum Decision: Equatable {
        case keep(Set<VaultItem.ID>)
        case stop
    }

    /// A choice that can be repeated on another set of exact copies.
    enum Pattern: Equatable {
        case keepAll, keepVaultOnly, keepNewOnly, keepOldestOnly, keepNewestOnly

        init?(keeping kept: Set<VaultItem.ID>, of group: Group) {
            let all = Set(group.copies.map(\.id))
            let incoming = Set(group.copies.filter(\.isNew).map(\.id))
            if kept == all {
                self = .keepAll
            } else if !incoming.isEmpty, kept == all.subtracting(incoming) {
                self = .keepVaultOnly
            } else if !incoming.isEmpty, kept == incoming {
                self = .keepNewOnly
            } else if incoming.isEmpty, kept.count == 1, kept.first == group.copies.first?.id {
                self = .keepOldestOnly
            } else if incoming.isEmpty, kept.count == 1, kept.first == group.copies.last?.id {
                self = .keepNewestOnly
            } else {
                return nil
            }
        }

        func keeps(in group: Group) -> Set<VaultItem.ID>? {
            let incoming = group.copies.filter(\.isNew).map(\.id)
            let resident = group.copies.filter { !$0.isNew }.map(\.id)
            switch self {
            case .keepAll: return Set(group.copies.map(\.id))
            case .keepVaultOnly: return incoming.isEmpty || resident.isEmpty ? nil : Set(resident)
            case .keepNewOnly: return incoming.isEmpty ? nil : Set(incoming)
            case .keepOldestOnly: return incoming.isEmpty ? group.copies.first.map { [$0.id] } : nil
            case .keepNewestOnly: return incoming.isEmpty ? group.copies.last.map { [$0.id] } : nil
            }
        }
    }

    let origin: Origin
    private(set) var group: Group?
    private(set) var counter = (current: 0, total: 0)
    private(set) var qualities: [VaultQuality]?
    var ticked: Set<VaultItem.ID> = []
    var focus = 0 {
        didSet { playback.follow(focus) }
    }
    var repeatsExactChoice = false
    private(set) var lastExactPattern: Pattern?
    let playback = VaultSyncedPlayback()
    let zoom = VaultZoomGroup()
    @ObservationIgnored private var answer: VaultComparisonAnswer?
    @ObservationIgnored private let playableURL: (VaultItem) async -> URL

    init(origin: Origin, playableURL: @escaping (VaultItem) async -> URL) {
        self.origin = origin
        self.playableURL = playableURL
    }

    var comparison: VaultQualityComparison? {
        guard let group, let qualities, qualities.count == group.copies.count else { return nil }
        return VaultQualityComparison(qualities, kind: group.kind)
    }

    var canConfirm: Bool { !ticked.isEmpty }

    /// Why the "do the same" box can't be ticked for the choice on screen, or nil when it can.
    var whyNoRepeat: String? {
        guard let group, group.match == .exact else { return "Only for exact copies." }
        guard !ticked.isEmpty else { return nil }
        return Pattern(keeping: ticked, of: group) == nil ? "Only when you keep one side, or all of them." : nil
    }

    /// Waits for the choice on `group`. A cancelled task gets `.stop`, so a lock never waits on the screen.
    func choose(_ group: Group, number: Int, of total: Int) async -> Decision {
        if group.match == .exact, repeatsExactChoice, let kept = lastExactPattern?.keeps(in: group) { return .keep(kept) }
        show(group, number: number, of: total)
        let answer = VaultComparisonAnswer()
        self.answer = answer
        let decision = await withTaskCancellationHandler {
            await answer.wait()
        } onCancel: {
            answer.give(.stop)
        }
        if self.answer === answer { self.answer = nil }
        return decision
    }

    func toggle(_ id: VaultItem.ID) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }

    func toggleFocused() {
        guard let copy = group?.copies.dropFirst(focus).first else { return }
        toggle(copy.id)
    }

    func moveFocus(by step: Int) {
        guard let count = group?.copies.count, count > 0 else { return }
        focus = min(max(focus + step, 0), count - 1)
    }

    func keepAll() { ticked = Set(group?.copies.map(\.id) ?? []) }

    func confirm() {
        guard canConfirm, let group else { return }
        if group.match == .exact { lastExactPattern = Pattern(keeping: ticked, of: group) }
        if lastExactPattern == nil { repeatsExactChoice = false }
        answer?.give(.keep(ticked))
    }

    func cancel() { answer?.give(.stop) }

    /// Closes the screen and lets go of every player: the vault is about to lock, or the review is over.
    func end() {
        answer?.give(.stop)
        answer = nil
        group = nil
        qualities = nil
        playback.release()
    }

    private func show(_ group: Group, number: Int, of total: Int) {
        self.group = group
        counter = (number, total)
        ticked = []
        focus = 0
        qualities = nil
        playback.release()
        zoom.reset()
        Task { await load(group) }
    }

    private func load(_ group: Group) async {
        var urls: [URL] = []
        var read: [VaultQuality] = []
        for copy in group.copies {
            let playable = copy.isIncoming ? copy.item.url : await playableURL(copy.item)
            urls.append(playable)
            read.append(await VaultQuality.read(copy.item, inVault: !copy.isIncoming, playable: playable))
        }
        guard self.group == group else { return }
        qualities = read
        if group.kind == .video { playback.load(urls) }
    }
}

/// One answer, given once, to whoever waits for it. The cancellation handler gives it from any thread.
final class VaultComparisonAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<VaultComparison.Decision, Never>?
    private var given: VaultComparison.Decision?

    func wait() async -> VaultComparison.Decision {
        await withCheckedContinuation { continuation in
            let ready: VaultComparison.Decision? = lock.withLock {
                if let given { return given }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func give(_ decision: VaultComparison.Decision) {
        let waiting: CheckedContinuation<VaultComparison.Decision, Never>? = lock.withLock {
            guard given == nil else { return nil }
            given = decision
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: decision)
    }
}
