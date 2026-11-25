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
        /// Mounts the vault, then reports a failure, as an attach that went wrong late would.
        case mountsThenFails(String)
        /// Ejects the vault, then reports a failure, as an eject that unmounted and then went wrong would.
        case ejectsThenFails(String)
        /// Runs on whatever the door's time limit says, as a wedged eject would. Ended by `killProgramsLeftRunning`.
        case ignoresItsTimeLimit
        /// The real tool on a bound a busy Mac can meet, whatever the door's bounds: for closing up after a test that gave it short ones.
        case realWithRoomToFinish
    }

    static let verbs = ["create", "attach", "chpass", "eject", "detach"]
    private static let hangingProgram = "exec /bin/sleep 30"

    let steps = Locked<[String]>([])
    private let realEjects = Locked<Set<Int>>([])
    let timeouts = Locked<[String: Shell.Timeout]>([:])
    let stopped = Locked<[String]>([])
    private let parts = Locked<[String: Part]>([:])
    private let closing = Locked((now: 0, most: 0))
    private let hanging = Locked<Set<String>>([])

    var mostClosingsAtOnce: Int { closing.value.most }

    /// The steps without a forced detach right after a real eject. On a busy Mac a real `diskutil eject` can be refused
    /// or run out its time, and the door then rightly forces a detach; that is not what these tests are about.
    var stepsForgivingABusyEject: [String] {
        let all = steps.value, real = realEjects.value
        return all.indices.filter { !(all[$0] == "detach" && real.contains($0 - 1)) }.map { all[$0] }
    }

    func play(_ verb: String, as part: Part) { parts.update { $0[verb] = part } }

    func isHanging(_ verb: String) -> Bool { hanging.value.contains(verb) }

    var tool: VaultTool {
        VaultTool { [self] path, arguments, input, timeout in
            let verb = arguments.first { Self.verbs.contains($0) } ?? path
            let part = parts.value[verb] ?? .real
            steps.update { steps in
                steps.append(verb)
                if verb == "eject", case .real = part { realEjects.update { $0.insert(steps.count - 1) } }
            }
            timeouts.update { $0[verb] = timeout }
            let closes = verb == "eject" || verb == "detach"
            if closes { closing.update { $0 = ($0.now + 1, max($0.most, $0.now + 1)) } }
            defer { if closes { closing.update { $0.now -= 1 } } }
            switch part {
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
            case .mountsThenFails(let message), .ejectsThenFails(let message):
                _ = try await VaultTool.system.run(path, arguments, input, timeout)
                return Shell.Result(status: 1, out: "", err: message)
            case .ignoresItsTimeLimit:
                return try await hang(verb, .untilFinished)
            case .realWithRoomToFinish:
                return try await VaultTool.system.run(path, arguments, input, .diskImage)
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
    /// A disk-tool time limit a busy Mac can meet, for tests about something other than the door's own limits.
    static var roomForABusyMac: TimeInterval { 30 }

    /// One test's folder for throwaway vaults. A test that wedges an eject on purpose can leave its image attached with
    /// nothing mounted, so when the test ends every image under this folder, and nothing else, is force-detached.
    func makeVaultTestFolder(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            self.killProgramsLeftRunning(file: file, line: line)
            for image in await Self.imagesAttached(under: folder) ?? [] {
                _ = try? await Shell.run(VaultDisk.hdiutil, ["detach", "-force", image.device], timeout: .seconds(60))
            }
            let left = await Self.imagesAttached(under: folder)?.map(\.path)
            XCTAssertEqual(left, [], "the test left disk images attached", file: file, line: line)
            try? FileManager.default.removeItem(at: folder)
        }
        return folder
    }

    /// Nil for a folder that is not a test's own vault folder, or when hdiutil could not say: never an empty answer from a failed look.
    static func imagesAttached(under folder: URL) async -> [(path: String, device: String)]? {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let scope = folder.resolvingSymlinksInPath().path
        guard scope.hasPrefix(temporary + "/vault-"),
              let info = try? await Shell.run(VaultDisk.hdiutil, ["info", "-plist"], timeout: .quick),
              let plist = try? PropertyListSerialization.propertyList(from: Data(info.out.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(scope + "/"),
                  let entities = image["system-entities"] as? [[String: Any]],
                  let wholeDisk = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) else { return nil }
            return (path, wholeDisk)
        }
    }

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
