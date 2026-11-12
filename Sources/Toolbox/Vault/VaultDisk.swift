import Foundation

struct VaultLocation: Equatable {
    let folder: URL

    var image: URL { folder.appendingPathComponent("Vault.sparsebundle") }
    var mountPoint: URL { folder.appendingPathComponent("Open.noindex") }

    static let standard = VaultLocation(folder: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Toolbox/.vault.noindex"))

    static func launch(arguments: [String] = CommandLine.arguments) -> VaultLocation {
        guard let flag = arguments.firstIndex(of: "--vault-folder"), flag + 1 < arguments.count else { return .standard }
        return VaultLocation(folder: URL(fileURLWithPath: arguments[flag + 1], isDirectory: true))
    }
}

enum VaultError: LocalizedError, Equatable {
    case wrongPassword
    case passwordTooShort
    case passwordsDiffer
    case alreadyExists
    case diskTool(action: String, message: String)

    static let minimumPasswordLength = 6

    var errorDescription: String? {
        switch self {
        case .wrongPassword: "That password doesn't open the vault."
        case .passwordTooShort: "Use at least \(Self.minimumPasswordLength) characters."
        case .passwordsDiffer: "The two passwords don't match."
        case .alreadyExists: "A vault already exists."
        case .diskTool(let action, let message): "The vault couldn't \(action). \(message)"
        }
    }
}

struct VaultDisk {
    static let diskutil = "/usr/sbin/diskutil"
    static let hdiutil = "/usr/bin/hdiutil"
    static let maximumSize = "2T"
    static let volumeName = "Vault"
    static let spotlightOptOut = ".metadata_never_index"

    let location: VaultLocation

    var exists: Bool { FileManager.default.fileExists(atPath: location.image.path) }

    var isOpen: Bool {
        let values = try? location.mountPoint.resourceValues(forKeys: [.isVolumeKey])
        return values?.isVolume == true
    }

    static func validateNewPassword(_ password: String, confirmation: String) throws {
        guard password.count >= VaultError.minimumPasswordLength else { throw VaultError.passwordTooShort }
        guard password == confirmation else { throw VaultError.passwordsDiffer }
    }

    func create(password: String) async throws {
        guard !exists else { throw VaultError.alreadyExists }
        try FileManager.default.createDirectory(at: location.folder, withIntermediateDirectories: true)
        try hideFolder()
        let result = try await Shell.run(Self.diskutil, ["image", "--stdinpass", "create", "blank", "--encrypt",
                                                         "--size", Self.maximumSize, "--volumeName", Self.volumeName,
                                                         "--fs", "APFS", location.image.path],
                                         input: Data(password.utf8))
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: location.image)
            throw VaultError.diskTool(action: "be created", message: Self.reason(result))
        }
    }

    func unlock(password: String) async throws {
        if isOpen { try await lock() }
        if !FileManager.default.fileExists(atPath: location.mountPoint.path) {
            try FileManager.default.createDirectory(at: location.mountPoint, withIntermediateDirectories: false)
        }
        let result = try await Shell.run(Self.diskutil, ["image", "--stdinpass", "attach", "--nobrowse",
                                                         "--mountPoint", location.mountPoint.path, location.image.path],
                                         input: Data(password.utf8))
        guard result.succeeded else {
            removeEmptyMountPoint()
            if Self.isWrongPassword(result) { throw VaultError.wrongPassword }
            throw VaultError.diskTool(action: "open", message: Self.reason(result))
        }
        try prepareVolume()
    }

    func lock() async throws {
        guard isOpen else { return removeEmptyMountPoint() }
        let eject = try await Shell.run(Self.diskutil, ["eject", location.mountPoint.path])
        if eject.succeeded || !isOpen { return removeEmptyMountPoint() }
        let forced = try await Shell.run(Self.hdiutil, ["detach", "-force", location.mountPoint.path])
        guard forced.succeeded || !isOpen else { throw VaultError.diskTool(action: "lock", message: Self.reason(forced)) }
        removeEmptyMountPoint()
    }

    func removeEmptyMountPoint() {
        let fileManager = FileManager.default
        guard !isOpen, let contents = try? fileManager.contentsOfDirectory(atPath: location.mountPoint.path), contents.isEmpty else { return }
        try? fileManager.removeItem(at: location.mountPoint)
    }

    func lockAndWait() {
        guard isOpen else { return removeEmptyMountPoint() }
        Self.runAndWait(Self.diskutil, ["eject", location.mountPoint.path])
        if isOpen { Self.runAndWait(Self.hdiutil, ["detach", "-force", location.mountPoint.path]) }
        removeEmptyMountPoint()
    }

    func changePassword(from old: String, to new: String) async throws {
        let result = try await Shell.run(Self.diskutil, ["image", "--stdinpass", "chpass", location.image.path],
                                         input: Data("\(old)\n\(new)\n".utf8))
        guard result.succeeded else {
            if Self.isWrongPassword(result) { throw VaultError.wrongPassword }
            throw VaultError.diskTool(action: "change its password", message: Self.reason(result))
        }
    }

    private func hideFolder() throws {
        var folder = location.folder
        var values = URLResourceValues()
        values.isHidden = true
        try folder.setResourceValues(values)
    }

    private func prepareVolume() throws {
        let optOut = location.mountPoint.appendingPathComponent(Self.spotlightOptOut)
        if !FileManager.default.fileExists(atPath: optOut.path) {
            FileManager.default.createFile(atPath: optOut.path, contents: Data())
        }
    }

    static func isWrongPassword(_ result: Shell.Result) -> Bool {
        let text = (result.err + result.out).lowercased()
        return text.contains("incorrect passphrase") || text.contains("authentication error")
    }

    static func reason(_ result: Shell.Result) -> String {
        let text = (result.err.isEmpty ? result.out : result.err).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "diskutil exited with status \(result.status)." : text
    }

    private static func runAndWait(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
