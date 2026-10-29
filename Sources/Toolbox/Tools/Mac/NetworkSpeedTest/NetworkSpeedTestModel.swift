import Foundation
import Observation

@MainActor @Observable
final class NetworkSpeedTestModel {
    static let shared = NetworkSpeedTestModel()
    private static let historyKey = "networkSpeedTest.history"
    private static let historyLimit = 20

    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var latest: SpeedResult?
    private(set) var connection: String?
    private(set) var history: [SpeedResult] = []
    var mode = NetworkQuality.Mode.together

    private var task: Task<Void, Never>?
    private let defaults: UserDefaults
    private let runTest: (NetworkQuality.Mode) async throws -> SpeedResult

    init(defaults: UserDefaults = .standard,
         runTest: @escaping (NetworkQuality.Mode) async throws -> SpeedResult = { try await NetworkQuality.run($0) }) {
        self.defaults = defaults
        self.runTest = runTest
        if let data = defaults.data(forKey: Self.historyKey), let saved = try? JSONDecoder().decode([SpeedResult].self, from: data) {
            history = saved
        }
    }

    var isRunning: Bool { state == .running }

    func start() {
        guard !isRunning else { return }
        state = .running
        let mode = mode
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runTest(mode)
                latest = result
                connection = await NetworkQuality.connectionKind(interface: result.interface)
                history.insert(result, at: 0)
                history = Array(history.prefix(Self.historyLimit))
                saveHistory()
                state = .idle
                Log.info("Speed test finished", category: "speedtest", ["mode": mode == .sequential ? "sequential" : "together"])
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
                Log.warning("Speed test failed", category: "speedtest", Log.details(error, ["mode": mode == .sequential ? "sequential" : "together"]))
            }
        }
    }

    func cancel() {
        task?.cancel()
        state = .idle
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.historyKey) }
    }
}
