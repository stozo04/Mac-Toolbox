import AppKit

/// Runs a command-line program without blocking the UI. The only place in the app that starts one.
enum Shell {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        var succeeded: Bool { status == 0 }
    }

    enum Timeout: Equatable {
        case seconds(TimeInterval)
        /// For work whose length follows the user's file or waits for the person. It ends when the calling task is cancelled or the app quits.
        case untilCancelled

        static let quick = Timeout.seconds(30)
        /// `diskutil image` is never stopped at quit and gets minutes: stopping it halfway through could damage the image.
        static let diskImage = Timeout.seconds(300)
    }

    enum ShellError: LocalizedError, Equatable {
        case launchFailed(String)
        case timedOut(String, TimeInterval)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let path): "Could not start \(Shell.name(path))."
            case .timedOut(let path, let seconds): "\(Shell.name(path)) did not finish within \(Int(seconds)) seconds, so it was stopped."
            }
        }
    }

    /// How long a program gets to end by itself after SIGTERM before it is sent SIGKILL.
    static let killGrace: TimeInterval = 2

    static var livePIDs: [Int32] { children.all().map(\.pid) }

    /// Cancelling the calling task stops the program, and the call then throws `CancellationError`.
    static func run(_ path: String, _ arguments: [String] = [], input: Data? = nil, timeout: Timeout,
                    onOutput: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let box = ProcessBox(process, path: path, endsWithApp: timeout == .untilCancelled)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                let outData = DataCollector(), errData = DataCollector()
                let text = UTF8Chunks()
                out.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    outData.append(chunk)
                    onOutput?(text.decode(chunk))
                }
                err.fileHandleForReading.readabilityHandler = { errData.append($0.availableData) }
                process.terminationHandler = { p in
                    let stopped = box.finish()
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    // A stopped program's children can keep the pipes open, so reading to the end could wait forever.
                    if let stopped { return continuation.resume(throwing: stopError(stopped, path: path)) }
                    let rest = out.fileHandleForReading.readDataToEndOfFile()
                    outData.append(rest)
                    if !rest.isEmpty { onOutput?(text.decode(rest)) }
                    errData.append(err.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: Result(status: p.terminationStatus, out: outData.string, err: errData.string))
                }
                do { try box.launch() } catch {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                if let inputPipe, let input {
                    try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inputPipe.fileHandleForWriting.close()
                }
                if case .seconds(let seconds) = timeout { box.requestStop(.timedOut(seconds), after: seconds) }
            }
        } onCancel: { box.requestStop(.cancelled) }
    }

    /// Cancels every program that would otherwise outlive the app. Blocks for at most `grace`, because the app is gone once quitting returns.
    static func stopChildrenBeforeQuit(grace: TimeInterval = killGrace) {
        let untilCancelled = { children.all().filter(\.endsWithApp) }
        untilCancelled().forEach { $0.requestStop(.cancelled) }
        let deadline = Date().addingTimeInterval(grace)
        while !untilCancelled().isEmpty, Date() < deadline { usleep(exitPollMicroseconds) }
        untilCancelled().forEach { $0.killIfStillRunning() }
    }

    private static let exitPollMicroseconds: UInt32 = 10_000
    private static let children = ChildRegistry()

    private static func name(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    private static func stopError(_ reason: ProcessBox.Stop, path: String) -> Error {
        switch reason {
        case .cancelled:
            return CancellationError()
        case .timedOut(let seconds):
            let error = ShellError.timedOut(path, seconds)
            Log.warning("Program timed out", category: "shell", Log.details(error, ["program": name(path)]))
            return error
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        enum Stop { case cancelled, timedOut(TimeInterval) }

        let endsWithApp: Bool
        private let process: Process
        private let path: String
        private let lock = NSLock()
        private var launched = false
        private var finished = false
        private var stopReason: Stop?
        private var timers: [DispatchWorkItem] = []

        var pid: Int32 { process.processIdentifier }

        init(_ process: Process, path: String, endsWithApp: Bool) {
            self.process = process
            self.path = path
            self.endsWithApp = endsWithApp
        }

        /// Holds the lock while the program starts, so a stop request lands either before the launch (which then never happens) or after it (and signals the program).
        func launch() throws {
            lock.lock(); defer { lock.unlock() }
            if stopReason != nil { throw CancellationError() }
            do { try process.run() } catch { throw ShellError.launchFailed(path) }
            launched = true
            Shell.children.add(self)
        }

        func requestStop(_ reason: Stop) {
            lock.lock(); defer { lock.unlock() }
            guard stopReason == nil, !finished else { return }
            stopReason = reason
            guard launched else { return }
            kill(pid, SIGTERM)
            schedule(after: Shell.killGrace) { [self] in killIfStillRunning() }
        }

        func requestStop(_ reason: Stop, after seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            schedule(after: seconds) { [self] in requestStop(reason) }
        }

        func finish() -> Stop? {
            lock.lock(); defer { lock.unlock() }
            finished = true
            timers.forEach { $0.cancel() }
            timers = []
            if launched { Shell.children.remove(self) }
            return stopReason
        }

        func killIfStillRunning() {
            lock.lock(); defer { lock.unlock() }
            if launched, !finished { kill(pid, SIGKILL) }
        }

        private func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
            guard !finished else { return }
            let timer = DispatchWorkItem(block: work)
            timers.append(timer)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
        }
    }

    private final class ChildRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var live: [ObjectIdentifier: ProcessBox] = [:]
        private var quitObserver: NSObjectProtocol?

        func add(_ child: ProcessBox) {
            lock.lock(); defer { lock.unlock() }
            live[ObjectIdentifier(child)] = child
            quitObserver = quitObserver ?? NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in Shell.stopChildrenBeforeQuit() }
        }

        func remove(_ child: ProcessBox) {
            lock.lock(); defer { lock.unlock() }
            live[ObjectIdentifier(child)] = nil
        }

        func all() -> [ProcessBox] {
            lock.lock(); defer { lock.unlock() }
            return Array(live.values)
        }
    }

    /// Output arrives in arbitrary pieces, so a character can be cut in two; the cut-off bytes wait for the next piece.
    private final class UTF8Chunks: @unchecked Sendable {
        private static let longestCharacter = 4
        private let lock = NSLock()
        private var pending = Data()

        func decode(_ chunk: Data) -> String {
            lock.lock(); defer { lock.unlock() }
            pending.append(chunk)
            for held in 0..<min(Self.longestCharacter, pending.count + 1) {
                guard let text = String(bytes: pending.dropLast(held), encoding: .utf8) else { continue }
                pending = Data(pending.suffix(held))
                return text
            }
            defer { pending = Data() }
            return String(decoding: pending, as: UTF8.self)
        }
    }

    private final class DataCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}
