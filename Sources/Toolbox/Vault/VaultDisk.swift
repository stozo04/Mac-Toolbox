import Foundation

struct VaultLocation: Equatable {
    let folder: URL

    var image: URL { folder.appendingPathComponent("Vault.sparsebundle") }
    var mountPoint: URL { folder.appendingPathComponent("Open.noindex") }

    static let standard = VaultLocation(folder: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Toolbox/.vault.noindex"))

    static let development = VaultLocation(folder: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Toolbox/.vault-dev.noindex"))

    static let debugFolderFlag = "--vault-folder"

    static func launch(arguments: [String] = CommandLine.arguments, isDevelopmentRun: Bool = AppInfo.isDevelopmentRun) -> VaultLocation {
        #if DEBUG
        if let flag = arguments.firstIndex(of: debugFolderFlag), flag + 1 < arguments.count {
            return VaultLocation(folder: URL(fileURLWithPath: arguments[flag + 1], isDirectory: true))
        }
        #endif
        return isDevelopmentRun ? .development : .standard
    }
}

enum VaultError: LocalizedError, Equatable {
    case wrongPassword
    case passwordTooShort
    case passwordsDiffer
    case alreadyExists
    case filesLeftOutside(count: Int, folder: String)
    case diskTool(action: String, message: String)

    static let minimumPasswordLength = 6

    var errorDescription: String? {
        switch self {
        case .wrongPassword: "That password doesn't open the vault."
        case .passwordTooShort: "Use at least \(Self.minimumPasswordLength) characters."
        case .passwordsDiffer: "The two passwords don't match."
        case .alreadyExists: "A vault already exists."
        case .filesLeftOutside(let count, let folder):
            "\(count == 1 ? "1 file was" : "\(count) files were") found in the vault's open folder, outside the vault: \(folder). "
                + "Move \(count == 1 ? "it" : "them") somewhere else, then unlock again."
        case .diskTool(let action, let message): "The vault couldn't \(action). \(message)"
        }
    }
}

struct VaultTool: Sendable {
    static let didNotFinish: Int32 = -1

    let run: @Sendable (_ path: String, _ arguments: [String], _ input: Data?, _ timeout: Shell.Timeout) async throws -> Shell.Result

    static let system = VaultTool { path, arguments, input, timeout in
        try await Shell.run(path, arguments, input: input, timeout: timeout)
    }
}

struct VaultDisk {
    static let diskutil = "/usr/sbin/diskutil"
    static let hdiutil = "/usr/bin/hdiutil"
    static let maximumSize = "2T"
    static let volumeName = "Vault"
    static let spotlightOptOut = ".metadata_never_index"
    static let harmlessLeftovers: Set<String> = [".DS_Store", spotlightOptOut]
    static let unfinishedPrefix = ".Vault-"
    static let unfinishedSuffix = ".sparsebundle"
    // Another copy of the app may be creating its image right now; one this old was left by a create that crashed.
    static let unfinishedIsAbandonedAfter: TimeInterval = 3600

    let location: VaultLocation
    var tool = VaultTool.system

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
        removeAbandonedUnfinishedImages()
        let unfinished = location.folder.appendingPathComponent("\(Self.unfinishedPrefix)\(UUID().uuidString)\(Self.unfinishedSuffix)")
        do {
            let result = try await tool.run(Self.diskutil, ["image", "--stdinpass", "create", "blank", "--encrypt",
                                                            "--size", Self.maximumSize, "--volumeName", Self.volumeName,
                                                            "--fs", "APFS", unfinished.path],
                                            Data(password.utf8), .untilFinished)
            guard result.succeeded else { throw VaultError.diskTool(action: "be created", message: Self.reason(result)) }
            try moveIntoPlace(unfinished)
        } catch {
            try? FileManager.default.removeItem(at: unfinished)
            throw Self.diskToolError(error, action: "be created")
        }
    }

    private func moveIntoPlace(_ unfinished: URL) throws {
        guard renamex_np(unfinished.path, location.image.path, UInt32(RENAME_EXCL)) != 0 else { return }
        let code = errno
        if code == EEXIST || code == ENOTEMPTY { throw VaultError.alreadyExists }
        throw VaultError.diskTool(action: "be created", message: String(cString: strerror(code)))
    }

    private func removeAbandonedUnfinishedImages() {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: location.folder.path)) ?? []
        for name in names where name.hasPrefix(Self.unfinishedPrefix) && name.hasSuffix(Self.unfinishedSuffix) {
            let leftover = location.folder.appendingPathComponent(name)
            let changed = (try? leftover.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let changed, Date().timeIntervalSince(changed) > Self.unfinishedIsAbandonedAfter else { continue }
            try? fileManager.removeItem(at: leftover)
        }
    }

    func unlock(password: String) async throws {
        if isOpen { try await lock() }
        try refuseFilesLeftOutside()
        if !FileManager.default.fileExists(atPath: location.mountPoint.path) {
            try FileManager.default.createDirectory(at: location.mountPoint, withIntermediateDirectories: false)
        }
        do {
            let result = try await tool.run(Self.diskutil, ["image", "--stdinpass", "attach", "--nobrowse",
                                                            "--mountPoint", location.mountPoint.path, location.image.path],
                                            Data(password.utf8), .diskImage)
            guard result.succeeded else {
                throw Self.isWrongPassword(result) ? VaultError.wrongPassword : VaultError.diskTool(action: "open", message: Self.reason(result))
            }
        } catch {
            try? await lock()
            removeEmptyMountPoint()
            throw Self.diskToolError(error, action: "open")
        }
        try prepareVolume()
    }

    func lock() async throws {
        guard isOpen else { return }
        let eject = await lockStep(Self.diskutil, ["eject", location.mountPoint.path])
        if eject.succeeded || !isOpen { return removeEmptyMountPoint() }
        let forced = await lockStep(Self.hdiutil, ["detach", "-force", location.mountPoint.path])
        guard forced.succeeded || !isOpen else { throw VaultError.diskTool(action: "lock", message: Self.reason(forced)) }
        removeEmptyMountPoint()
    }

    private func lockStep(_ path: String, _ arguments: [String]) async -> Shell.Result {
        do {
            return try await tool.run(path, arguments, nil, .diskImage)
        } catch {
            return Shell.Result(status: VaultTool.didNotFinish, out: "", err: error.localizedDescription)
        }
    }

    private func refuseFilesLeftOutside() throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: location.mountPoint.path)) ?? []
        let leftOutside = names.filter { !Self.harmlessLeftovers.contains($0) }
        guard leftOutside.isEmpty else {
            let folder = (location.mountPoint.path as NSString).abbreviatingWithTildeInPath
            throw VaultError.filesLeftOutside(count: leftOutside.count, folder: folder)
        }
    }

    static func diskToolError(_ error: Error, action: String) -> Error {
        error is VaultError || error is CancellationError ? error : VaultError.diskTool(action: action, message: error.localizedDescription)
    }

    func removeEmptyMountPoint() {
        let fileManager = FileManager.default
        guard !isOpen, let contents = try? fileManager.contentsOfDirectory(atPath: location.mountPoint.path), contents.isEmpty else { return }
        try? fileManager.removeItem(at: location.mountPoint)
    }

    func lockAndWait() {
        guard isOpen else { return }
        Self.runAndWait(Self.diskutil, ["eject", location.mountPoint.path])
        if isOpen { Self.runAndWait(Self.hdiutil, ["detach", "-force", location.mountPoint.path]) }
        removeEmptyMountPoint()
    }

    func changePassword(from old: String, to new: String) async throws {
        let result = try await tool.run(Self.diskutil, ["image", "--stdinpass", "chpass", location.image.path],
                                        Data("\(old)\n\(new)\n".utf8), .untilFinished)
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
