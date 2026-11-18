import XCTest
@testable import Toolbox

/// Stands in for diskutil and hdiutil: records what the door asked for and plays the part a test gives each verb.
final class DoorStandIn: @unchecked Sendable {
    enum Part: Sendable {
        case real
        case fails(String)
        case cannotStart
        /// Runs until the door stops it, as a slow attach would.
        case hangs
        case mountsThenHangs
        /// Runs on whatever the door's time limit says, as a wedged eject would. Ended by `killProgramsLeftRunning`.
        case ignoresItsTimeLimit
    }

    static let verbs = ["create", "attach", "chpass", "eject", "detach"]
    private static let hangingProgram = "exec /bin/sleep 30"

    let steps = Locked<[String]>([])
    let timeouts = Locked<[String: Shell.Timeout]>([:])
    let stopped = Locked<[String]>([])
    private let parts = Locked<[String: Part]>([:])
    private let closing = Locked((now: 0, most: 0))
    private let hanging = Locked<Set<String>>([])

    var mostClosingsAtOnce: Int { closing.value.most }

    func play(_ verb: String, as part: Part) { parts.update { $0[verb] = part } }

    func isHanging(_ verb: String) -> Bool { hanging.value.contains(verb) }

    var tool: VaultTool {
        VaultTool { [self] path, arguments, input, timeout in
            let verb = arguments.first { Self.verbs.contains($0) } ?? path
            steps.update { $0.append(verb) }
            timeouts.update { $0[verb] = timeout }
            let closes = verb == "eject" || verb == "detach"
            if closes { closing.update { $0 = ($0.now + 1, max($0.most, $0.now + 1)) } }
            defer { if closes { closing.update { $0.now -= 1 } } }
            switch parts.value[verb] ?? .real {
            case .real:
                return try await VaultTool.system.run(path, arguments, input, timeout)
            case .fails(let message):
                return Shell.Result(status: 1, out: "", err: message)
            case .cannotStart:
                throw Shell.ShellError.launchFailed(path)
            case .hangs:
                return try await hang(verb, timeout)
            case .mountsThenHangs:
                _ = try await VaultTool.system.run(path, arguments, input, timeout)
                return try await hang(verb, timeout)
            case .ignoresItsTimeLimit:
                return try await hang(verb, .untilFinished)
            }
        }
    }

    private func hang(_ verb: String, _ timeout: Shell.Timeout) async throws -> Shell.Result {
        hanging.update { $0.insert(verb) }
        defer { hanging.update { $0.remove(verb) } }
        do {
            return try await VaultTool.system.run("/bin/sh", ["-c", Self.hangingProgram], nil, timeout)
        } catch {
            stopped.update { $0.append(verb) }
            throw error
        }
    }
}

extension XCTestCase {
    static var vaultPassword: String { "door-pass" }

    /// A door on a throwaway folder that is locked again when the test ends, so nothing stays mounted.
    func makeDoor(in folder: URL, tool: VaultTool = .system, bounds: VaultDoor.Bounds = VaultDoor.Bounds(),
                  anotherCopyIsRunning: @escaping @Sendable () -> Bool = { false }) -> VaultDoor {
        let door = VaultDoor(location: VaultLocation(folder: folder), tool: tool, bounds: bounds, anotherCopyIsRunning: anotherCopyIsRunning)
        addTeardownBlock {
            _ = await door.lock()
            await Self.detachWhateverIsLeft(at: door.disk)
        }
        return door
    }

    func makeVaultImage(in folder: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let refusal = await VaultDoor(location: VaultLocation(folder: folder)).create(password: Self.vaultPassword)
        XCTAssertNil(refusal, file: file, line: line)
    }

    func makeOpenDoor(in folder: URL, tool: VaultTool = .system, bounds: VaultDoor.Bounds = VaultDoor.Bounds(),
                      file: StaticString = #filePath, line: UInt = #line) async throws -> VaultDoor {
        try await makeVaultImage(in: folder, file: file, line: line)
        let door = makeDoor(in: folder, tool: tool, bounds: bounds)
        let outcome = await door.unlock(password: Self.vaultPassword)
        XCTAssertEqual(outcome, .opened, file: file, line: line)
        XCTAssertTrue(door.disk.isOpen, file: file, line: line)
        return door
    }

    /// A test that leaves a volume mounted on purpose (another copy's, a stuck one) still must not leave it on the Mac.
    static func detachWhateverIsLeft(at disk: VaultDisk) async {
        let mountPoint = disk.location.mountPoint.resolvingSymlinksInPath().path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard disk.isOpen, mountPoint.hasPrefix(temporary + "/vault-") else { return }
        _ = try? await Shell.run(VaultDisk.hdiutil, ["detach", "-force", mountPoint], timeout: .seconds(60))
        disk.removeEmptyMountPoint()
    }
}
