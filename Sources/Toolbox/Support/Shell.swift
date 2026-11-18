import AppKit

/// Runs a command-line program without blocking the UI.
enum Shell {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        var succeeded: Bool { status == 0 }
    }

    enum Timeout: Equatable {
        case seconds(TimeInterval)
        /// For work whose length follows the user's file or that waits for the person; quitting the app cancels it too.
        case untilCancelled

        /// Never stopped, by a timer, a cancel or quitting: for a write that could damage what it writes if cut off halfway.
        case untilFinished

        static let quick = Timeout.seconds(30)
        /// Mounting and ejecting a disk image can take a while on a busy disk; neither is harmed by being stopped.
        static let diskImage = Timeout.seconds(300)
    }

    enum ShellError: LocalizedError, Equatable {
        case launchFailed(String)
        case timedOut(String, TimeInterval)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let path): "Could not start \(Shell.name(path))."
            case .timedOut(let path, let seconds): "\(Shell.name(path)) did not finish within \(Self.wording(of: seconds)), so it was stopped."
            }
        }

        static func wording(of seconds: TimeInterval) -> String {
            let amount = seconds.formatted(.number.precision(.fractionLength(0...1)))
            return amount == 1.formatted() ? "1 second" : "\(amount) seconds"
        }
    }

    static let secondsFromTerminateToKill: TimeInterval = 2

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
                let text = UTF8Chunks()
                let outDrain = PipeDrain(out.fileHandleForReading) { chunk in onOutput?(text.decode(chunk)) }
                let errDrain = PipeDrain(err.fileHandleForReading)
                process.terminationHandler = { p in
                    // A stopped program's children can keep the pipes open, so its output is not waited for.
                    if let stopped = box.finish() { return continuation.resume(throwing: stopError(stopped, path: path)) }
                    outDrain.waitUntilEmptied()
                    errDrain.waitUntilEmptied()
                    continuation.resume(returning: Result(status: p.terminationStatus, out: outDrain.string, err: errDrain.string))
                }
                do { try box.launch() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                outDrain.start()
                errDrain.start()
                if let inputPipe, let input {
                    try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inputPipe.fileHandleForWriting.close()
                }
                if case .seconds(let seconds) = timeout { box.requestStop(.timedOut(seconds), after: seconds) }
            }
        } onCancel: { if timeout != .untilFinished { box.requestStop(.cancelled) } }
    }

    /// Blocks for at most `grace`: the app is gone once quitting returns, so nothing scheduled for later would run.
    static func stopChildrenBeforeQuit(grace: TimeInterval = secondsFromTerminateToKill) {
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
            schedule(after: Shell.secondsFromTerminateToKill) { [self] in killIfStillRunning() }
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

    /// Reads a pipe to its end on one thread of its own, so the pieces stay in order and none is left behind when the program exits.
    private final class PipeDrain: @unchecked Sendable {
        private static let secondsToWaitAfterExit: TimeInterval = 5
        private let handle: FileHandle
        private let onChunk: (@Sendable (Data) -> Void)?
        private let emptied = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var data = Data()

        init(_ handle: FileHandle, onChunk: (@Sendable (Data) -> Void)? = nil) {
            self.handle = handle
            self.onChunk = onChunk
        }

        func start() {
            Thread.detachNewThread { [self] in
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    lock.lock(); data.append(chunk); lock.unlock()
                    onChunk?(chunk)
                }
                emptied.signal()
            }
        }

        /// Bounded, because a child the program left running can hold the pipe open after the program itself has exited.
        func waitUntilEmptied() {
            _ = emptied.wait(timeout: .now() + Self.secondsToWaitAfterExit)
        }

        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}
