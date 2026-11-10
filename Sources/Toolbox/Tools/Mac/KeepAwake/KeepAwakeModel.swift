import Foundation
import Observation

@MainActor @Observable
final class KeepAwakeModel {
    /// Shared so the timer keeps running while another tool is open.
    static let shared = KeepAwakeModel()

    enum Duration: Int, CaseIterable, Identifiable {
        case min30 = 1800, hour1 = 3600, hour2 = 7200, hour4 = 14400, hour8 = 28800, hour12 = 43200, forever = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .min30: "30 Minutes"
            case .hour1: "1 Hour"
            case .hour2: "2 Hours"
            case .hour4: "4 Hours"
            case .hour8: "8 Hours"
            case .hour12: "12 Hours"
            case .forever: "No Limit"
            }
        }
        var seconds: TimeInterval? { self == .forever ? nil : TimeInterval(rawValue) }
    }

    enum State: Equatable {
        case off
        /// Awake. `until` is nil when there is no timer.
        case awake(until: Date?)
        /// The timer is running but the Mac is on battery and "only on power adapter" is set.
        case waitingForPower(until: Date?)
    }

    private(set) var state = State.off
    var duration = Duration.hour1
    var keepDisplayOn = true { didSet { if keepDisplayOn != oldValue { refresh() } } }
    var onlyOnPowerAdapter = false { didSet { if onlyOnPowerAdapter != oldValue { refresh() } } }

    private let assertions: SleepPreventer
    private let now: () -> Date
    private let onPowerAdapter: () -> Bool
    private var timer: Task<Void, Never>?
    private var powerObserver: AnyObject?
    /// The display setting of the assertions we hold, so a repeat refresh leaves them alone.
    private var heldDisplay: Bool?

    var isOn: Bool { state != .off }

    init(assertions: SleepPreventer = PowerAssertions(), now: @escaping () -> Date = Date.init,
         onPowerAdapter: @escaping () -> Bool = { PowerSource.isOnPowerAdapter }) {
        self.assertions = assertions
        self.now = now
        self.onPowerAdapter = onPowerAdapter
    }

    /// Starting again replaces the current timer.
    func start() {
        let end = duration.seconds.map { now().addingTimeInterval($0) }
        state = .awake(until: end)
        refresh()
        scheduleEnd(end)
        if powerObserver == nil {
            powerObserver = PowerSource.observe { [weak self] in self?.refresh() }
        }
        Log.info("Keep awake started", category: "keepawake", ["timed": String(end != nil)])
    }

    func stop() {
        timer?.cancel()
        timer = nil
        powerObserver = nil
        assertions.release()
        heldDisplay = nil
        state = .off
    }

    /// Applies the toggles and the power source to what is currently held. The power source notifies on every
    /// charge-level change while plugged in, so this must not touch assertions that are already right.
    func refresh() {
        let end: Date?
        switch state {
        case .off: return
        case .awake(let until), .waitingForPower(let until): end = until
        }
        if onlyOnPowerAdapter && !onPowerAdapter() {
            assertions.release()
            heldDisplay = nil
            state = .waitingForPower(until: end)
        } else {
            if !assertions.isHeld || heldDisplay != keepDisplayOn {
                assertions.hold(keepDisplayOn: keepDisplayOn, reason: "Toolbox Keep Awake")
                heldDisplay = keepDisplayOn
            }
            state = .awake(until: end)
        }
    }

    func remaining(at date: Date) -> TimeInterval? {
        switch state {
        case .off: nil
        case .awake(let until), .waitingForPower(let until): until.map { max(0, $0.timeIntervalSince(date)) }
        }
    }

    private func scheduleEnd(_ end: Date?) {
        timer?.cancel()
        guard let end else { return }
        timer = Task { [weak self] in
            while let self, !Task.isCancelled {
                let left = end.timeIntervalSince(self.now())
                if left <= 0 { self.stop(); return }
                try? await Task.sleep(for: .seconds(min(left, 5)))
            }
        }
    }

    /// "0:59:42" or "12:05".
    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
