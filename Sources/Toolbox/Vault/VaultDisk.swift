import Foundation

struct VaultLocation: Equatable, Sendable {
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
    case openInAnotherCopy
    case diskTool(action: String, message: String)

    static let minimumPasswordLength = 6

    var errorDescription: String? {
        switch self {
        case .wrongPassword: "That password doesn't open the vault."
        case .passwordTooShort: "Use at least \(Self.minimumPasswordLength) characters."
        case .passwordsDiffer: "The two passwords don't match."
        case .alreadyExists: "A vault already exists."
        case .openInAnotherCopy: "The vault is open in another copy of Toolbox. Lock it there first."
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

/// What is on disk for the vault and what can be read from it without running a program. `VaultDoor` does the rest.
struct VaultDisk: Sendable {
    static let diskutil = "/usr/sbin/diskutil"
    static let hdiutil = "/usr/bin/hdiutil"
    static let spotlightOptOut = ".metadata_never_index"
    static let harmlessLeftovers: Set<String> = [".DS_Store", spotlightOptOut]
    static let unfinishedPrefix = ".Vault-"
    static let unfinishedSuffix = ".sparsebundle"
    // Another copy of the app may be creating its image right now; one this old was left by a create that crashed.
    static let unfinishedIsAbandonedAfter: TimeInterval = 3600

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

    func prepareFolder() throws {
        try FileManager.default.createDirectory(at: location.folder, withIntermediateDirectories: true)
        var folder = location.folder
        var values = URLResourceValues()
        values.isHidden = true
        try folder.setResourceValues(values)
        removeAbandonedUnfinishedImages()
    }

    func moveIntoPlace(_ unfinished: URL) throws {
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

    func refuseFilesLeftOutside() throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: location.mountPoint.path)) ?? []
        let leftOutside = names.filter { !Self.harmlessLeftovers.contains($0) }
        guard leftOutside.isEmpty else {
            let folder = (location.mountPoint.path as NSString).abbreviatingWithTildeInPath
            throw VaultError.filesLeftOutside(count: leftOutside.count, folder: folder)
        }
    }

    func removeEmptyMountPoint() {
        let fileManager = FileManager.default
        guard !isOpen, let contents = try? fileManager.contentsOfDirectory(atPath: location.mountPoint.path), contents.isEmpty else { return }
        try? fileManager.removeItem(at: location.mountPoint)
    }

    func markVolumeUnsearchable() {
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
}
