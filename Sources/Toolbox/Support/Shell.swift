import Foundation

/// Runs a command-line program without blocking the UI. Used by the Mac tools that wrap system utilities.
enum Shell {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        var succeeded: Bool { status == 0 }
    }

    enum ShellError: LocalizedError {
        case launchFailed(String)
        var errorDescription: String? {
            switch self { case .launchFailed(let path): "Could not start \(URL(fileURLWithPath: path).lastPathComponent)." }
        }
    }

    /// Cancelling the calling task stops the program.
    static func run(_ path: String, _ arguments: [String] = [], input: Data? = nil, timeout: TimeInterval? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let box = ProcessBox(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                let outData = DataCollector(), errData = DataCollector()
                out.fileHandleForReading.readabilityHandler = { outData.append($0.availableData) }
                err.fileHandleForReading.readabilityHandler = { errData.append($0.availableData) }
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    outData.append(out.fileHandleForReading.readDataToEndOfFile())
                    errData.append(err.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: Result(status: p.terminationStatus, out: outData.string, err: errData.string))
                }
                do { try process.run() } catch {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ShellError.launchFailed(path))
                    return
                }
                if let inputPipe, let input {
                    try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inputPipe.fileHandleForWriting.close()
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.terminate() }
                }
            }
        } onCancel: { box.terminate() }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() { if process.isRunning { process.terminate() } }
    }

    private final class DataCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}
