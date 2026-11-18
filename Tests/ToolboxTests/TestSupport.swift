import AppKit
import AVFoundation
import XCTest
@testable import Toolbox

struct TestSupportFailure: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }

    init(_ message: String, file: StaticString, line: UInt) {
        description = "\(message) (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))"
    }
}

func missingTools(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Error {
    ProcessInfo.processInfo.environment["CI"] == "true" ? TestSupportFailure(message, file: file, line: line) : XCTSkip(message)
}

private let pollInterval = Duration.milliseconds(1)

@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ what: String, file: StaticString = #filePath, line: UInt = #line,
               _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            throw TestSupportFailure("Timed out after \(timeout) waiting until \(what)", file: file, line: line)
        }
        try await Task.sleep(for: pollInterval)
    }
}

func waitUntilReady(_ input: AVAssetWriterInput, of writer: AVAssetWriter, timeout: Duration = .seconds(60),
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + timeout
    while !input.isReadyForMoreMediaData {
        guard writer.status != .failed else {
            throw TestSupportFailure("The writer failed: \(writer.error?.localizedDescription ?? "no error given")", file: file, line: line)
        }
        guard ContinuousClock.now < deadline else {
            throw TestSupportFailure("Timed out after \(timeout) waiting until the writer input takes more data", file: file, line: line)
        }
        try await Task.sleep(for: pollInterval)
    }
}

func pause(for duration: Duration, because reason: String) async throws {
    try await Task.sleep(for: duration)
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) { update { $0 = value } }

    func update(_ change: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&stored)
    }
}

func isRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

extension XCTestCase {
    func killAfterTest(_ pid: Locked<Int32?>) {
        addTeardownBlock { if let pid = pid.value { kill(pid, SIGKILL) } }
    }

    func killProgramsLeftRunning(file: StaticString = #filePath, line: UInt = #line) {
        let left = Shell.livePIDs
        left.forEach { kill($0, SIGKILL) }
        XCTAssertEqual(left, [], "programs were still running when the test ended", file: file, line: line)
    }

    // A suite named by an absolute path keeps its plist there, so cfprefsd never writes one into ~/Library/Preferences.
    func makeScratchDefaultsDomain(prefix: String = "toolbox.tests") throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix).\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("defaults").path
    }

    func makeScratchDefaults(prefix: String = "toolbox.tests", file: StaticString = #filePath, line: UInt = #line) throws -> UserDefaults {
        let domain = try makeScratchDefaultsDomain(prefix: prefix)
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw TestSupportFailure("No defaults suite at \(domain)", file: file, line: line)
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        return defaults
    }

    func makeScratchPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("toolbox.tests.\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }
}

extension RandomAccessCollection where Index == Int {
    func element(at index: Int, file: StaticString = #filePath, line: UInt = #line) throws -> Element {
        guard indices.contains(index) else {
            throw TestSupportFailure("No element at \(index): the collection has \(count)", file: file, line: line)
        }
        return self[index]
    }
}

struct RGBAPixels {
    let bytes: [UInt8]
    let width: Int
    let height: Int

    init(bytes: [UInt8], width: Int, height: Int) {
        self.bytes = bytes
        self.width = width
        self.height = height
    }

    init(_ image: CGImage, space: CGColorSpace = CGColorSpaceCreateDeviceRGB(), alpha: CGImageAlphaInfo) throws {
        let (w, h) = (image.width, image.height)
        var drawn = [UInt8](repeating: 0, count: w * h * 4)
        try drawn.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: alpha.rawValue) else {
                throw CocoaError(.fileReadUnknown)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.init(bytes: drawn, width: w, height: h)
    }

    func components(_ x: Int, _ y: Int, file: StaticString = #filePath, line: UInt = #line) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard (0..<width).contains(x), (0..<height).contains(y), bytes.count >= width * height * 4 else {
            throw TestSupportFailure("No pixel at (\(x), \(y)) in a \(width) x \(height) image", file: file, line: line)
        }
        let start = (y * width + x) * 4
        return (bytes[start], bytes[start + 1], bytes[start + 2], bytes[start + 3])
    }

    func rgba(_ x: Int, _ y: Int, file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        let p = try components(x, y, file: file, line: line)
        return [p.r, p.g, p.b, p.a]
    }

    func rgb(_ x: Int, _ y: Int, file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        let p = try components(x, y, file: file, line: line)
        return [p.r, p.g, p.b]
    }
}
