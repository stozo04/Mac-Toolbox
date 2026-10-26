import Foundation

struct SupabaseLogConfig: Sendable {
    var url: URL
    /// Publishable (anon) key. Safe to ship: the table only allows inserts.
    var key: String
    var table = "mactoolkit_app_logs"

    /// Env vars win (for development), then ~/Library/Application Support/Toolbox/logging.json
    /// with {"url": "...", "key": "..."}. Returns nil when not configured, so logging stays local.
    static func load() -> SupabaseLogConfig? {
        let env = ProcessInfo.processInfo.environment
        if let u = env["TOOLBOX_SUPABASE_URL"].flatMap(URL.init(string:)), let k = env["TOOLBOX_SUPABASE_KEY"] {
            return SupabaseLogConfig(url: u, key: k)
        }
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox/logging.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONDecoder().decode([String: String].self, from: data),
              let u = json["url"].flatMap(URL.init(string:)), let k = json["key"] else { return nil }
        return SupabaseLogConfig(url: u, key: k)
    }
}

/// Sends events to a Supabase table through its REST API, in small batches.
/// Errors and criticals go out right away; everything else waits for the next flush.
/// If the network is down the events stay queued (up to `maxQueued`, oldest dropped first).
final class SupabaseLogSink: LogSink, @unchecked Sendable {
    let minimumLevel: LogLevel
    private let config: SupabaseLogConfig
    private let session: URLSession
    private let maxQueued = 500
    private let flushInterval: TimeInterval

    private let lock = NSLock()
    private var queue: [LogEvent] = []
    private var sending = false
    private var timer: Timer?

    init(config: SupabaseLogConfig, minimumLevel: LogLevel = .warning,
         flushInterval: TimeInterval = 10, session: URLSession = .shared) {
        self.config = config
        self.minimumLevel = minimumLevel
        self.flushInterval = flushInterval
        self.session = session
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
    }

    func write(_ event: LogEvent) {
        lock.lock()
        queue.append(event)
        if queue.count > maxQueued { queue.removeFirst(queue.count - maxQueued) }
        lock.unlock()
        if event.level >= .error { flush() }
    }

    func flush() {
        guard let batch = beginSend() else { return }
        Task { endSend(sent: batch.count, success: await send(batch)) }
    }

    private func beginSend() -> [LogEvent]? {
        lock.lock(); defer { lock.unlock() }
        guard !sending, !queue.isEmpty else { return nil }
        sending = true
        return queue
    }

    private func endSend(sent: Int, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        if success { queue.removeFirst(min(sent, queue.count)) }
        sending = false
    }

    func request(for batch: [LogEvent]) throws -> URLRequest {
        var req = URLRequest(url: config.url.appendingPathComponent("rest/v1/\(config.table)"))
        req.httpMethod = "POST"
        req.setValue(config.key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        req.httpBody = try encoder.encode(batch)
        req.timeoutInterval = 15
        return req
    }

    private func send(_ batch: [LogEvent]) async -> Bool {
        guard let req = try? request(for: batch),
              let (_, response) = try? await session.data(for: req),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        // 4xx means the batch itself is bad; retrying forever would block the queue, so drop it.
        return (200..<500).contains(status)
    }
}
