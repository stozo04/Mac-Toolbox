import AppKit

struct AppDetails: Equatable {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let signature: CodeSignInfo
    let assessment: Assessment
    let isQuarantined: Bool
}

enum Assessment: Equatable {
    case notarized
    case developerID
    case appStore
    case rejected(String)
    case unknown
}

enum AppInspector {
    enum InspectError: LocalizedError {
        case notAnApp
        case systemApp
        var errorDescription: String? {
            switch self {
            case .notAnApp: "That isn't an app. Choose a file that ends in .app."
            case .systemApp: "This is part of macOS and can't be changed here."
            }
        }
    }

    /// Reads `spctl --assess -vv`, which prints e.g. "accepted" and "source=Notarized Developer ID".
    static func parseAssessment(status: Int32, output: String) -> Assessment {
        let text = output.lowercased()
        if status == 0 {
            if text.contains("notarized developer id") { return .notarized }
            if text.contains("developer id") { return .developerID }
            if text.contains("mac app store") { return .appStore }
            return .unknown
        }
        if text.contains("rejected") {
            if text.contains("a sealed resource is missing or invalid") || text.contains("code has no resources but signature indicates they must be present") {
                return .rejected("Files inside the app were changed after it was signed.")
            }
            if text.contains("source=no usable signature") { return .rejected("The app is not signed.") }
            if text.contains("source=unnotarized developer id") { return .rejected("The developer did not have the app approved (notarized) by Apple.") }
            return .rejected("macOS's security check does not approve this app.")
        }
        return .unknown
    }

    static func inspect(_ url: URL) async throws -> AppDetails {
        guard url.pathExtension.lowercased() == "app" else { throw InspectError.notAnApp }
        if url.path.hasPrefix("/System/") { throw InspectError.systemApp }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        let spctl = try? await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", url.path], timeout: 30)
        let assessment = spctl.map { parseAssessment(status: $0.status, output: $0.out + $0.err) } ?? .unknown
        return AppDetails(url: url, name: name, bundleID: bundle?.bundleIdentifier,
                          version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                          signature: CodeSignInfo.inspect(url), assessment: assessment, isQuarantined: Quarantine.isQuarantined(url))
    }
}

/// The "downloaded from the internet" flag macOS puts on files, which triggers Gatekeeper's checks.
enum Quarantine {
    static let attribute = "com.apple.quarantine"

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Removes the flag from the app and everything inside it. Returns how many files had it.
    @discardableResult
    static func clear(at url: URL) throws -> Int {
        var cleared = 0
        func clearOne(_ u: URL) throws {
            if removexattr(u.path, attribute, XATTR_NOFOLLOW) == 0 { cleared += 1; return }
            let code = errno
            // Not having the flag is fine; anything else (read-only volume, no permission) is a real failure.
            if code != ENOATTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: u.path]) }
        }
        try clearOne(url)
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true })
        while let item = walker?.nextObject() as? URL { try clearOne(item) }
        return cleared
    }

    static func message(for error: Error) -> String {
        let code = (error as NSError).code
        if (error as NSError).domain == NSPOSIXErrorDomain, code == Int(EPERM) || code == Int(EACCES) {
            return "macOS didn't allow the change. If the app is in Applications, give Toolbox “App Management” access in System Settings › Privacy & Security, then try again."
        }
        if (error as NSError).domain == NSPOSIXErrorDomain, code == Int(EROFS) { return "The app is on a read-only disk. Copy it to Applications first." }
        return "The quarantine could not be cleared."
    }
}
