import AppKit

/// A privacy permission that `tccutil` can reset for one app.
struct PrivacyService: Identifiable, Hashable {
    let id: String          // the name tccutil expects
    let title: String
    let symbol: String

    static let all: [PrivacyService] = [
        PrivacyService(id: "ScreenCapture", title: "Screen Recording", symbol: "record.circle"),
        PrivacyService(id: "Microphone", title: "Microphone", symbol: "mic.fill"),
        PrivacyService(id: "Camera", title: "Camera", symbol: "camera.fill"),
        PrivacyService(id: "Accessibility", title: "Accessibility", symbol: "accessibility"),
        PrivacyService(id: "ListenEvent", title: "Input Monitoring", symbol: "keyboard"),
        PrivacyService(id: "SystemPolicyAllFiles", title: "Full Disk Access", symbol: "internaldrive"),
        PrivacyService(id: "AppleEvents", title: "Automation", symbol: "gearshape.2"),
        PrivacyService(id: "Photos", title: "Photos", symbol: "photo"),
        PrivacyService(id: "AddressBook", title: "Contacts", symbol: "person.crop.circle"),
        PrivacyService(id: "Calendar", title: "Calendars", symbol: "calendar"),
        PrivacyService(id: "Reminders", title: "Reminders", symbol: "checklist"),
        PrivacyService(id: "SystemPolicyDesktopFolder", title: "Desktop Folder", symbol: "menubar.dock.rectangle"),
        PrivacyService(id: "SystemPolicyDocumentsFolder", title: "Documents Folder", symbol: "doc"),
        PrivacyService(id: "SystemPolicyDownloadsFolder", title: "Downloads Folder", symbol: "arrow.down.circle"),
        PrivacyService(id: "BluetoothAlways", title: "Bluetooth", symbol: "dot.radiowaves.left.and.right"),
        PrivacyService(id: "SpeechRecognition", title: "Speech Recognition", symbol: "waveform"),
    ]

    /// The privacy page in System Settings where the person can grant it again.
    var settingsPane: String {
        switch id {
        case "ScreenCapture": "Privacy_ScreenCapture"
        case "Microphone": "Privacy_Microphone"
        case "Camera": "Privacy_Camera"
        case "Accessibility": "Privacy_Accessibility"
        case "ListenEvent": "Privacy_ListenEvent"
        case "SystemPolicyAllFiles": "Privacy_AllFiles"
        case "AppleEvents": "Privacy_Automation"
        case "Photos": "Privacy_Photos"
        case "AddressBook": "Privacy_Contacts"
        case "Calendar": "Privacy_Calendars"
        case "Reminders": "Privacy_Reminders"
        case "BluetoothAlways": "Privacy_Bluetooth"
        case "SpeechRecognition": "Privacy_SpeechRecognition"
        default: "Privacy_FilesAndFolders"
        }
    }
}

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    var id: String { bundleID }
}

enum PermissionResetter {
    /// Bundle identifiers are reverse-DNS names. Anything else is refused, so nothing odd reaches the command.
    static func isValidBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 255 && id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil
    }

    /// Always names an app: resetting "All" for every app is not offered.
    static func arguments(service: String, bundleID: String) -> [String]? {
        guard isValidBundleID(bundleID), service == "All" || PrivacyService.all.contains(where: { $0.id == service }) else { return nil }
        return ["reset", service, bundleID]
    }

    enum ResetError: LocalizedError {
        case invalid
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .invalid: "That app's identifier can't be used."
            case .failed(let m): m.isEmpty ? "The permission could not be reset." : m
            }
        }
    }

    static func reset(service: String, bundleID: String) async throws {
        guard let args = arguments(service: service, bundleID: bundleID) else { throw ResetError.invalid }
        let result = try await Shell.run("/usr/bin/tccutil", args, timeout: 20)
        guard result.succeeded else {
            // tccutil only knows apps that macOS has registered, i.e. installed ones.
            if result.err.contains("No such bundle identifier") { throw ResetError.failed("macOS doesn't know this app. Open it once from its installed location, then try again.") }
            throw ResetError.failed(result.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Apps in the usual folders, with their identifiers. Apple's own apps are left out.
    static func installedApps() -> [InstalledApp] {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var apps: [InstalledApp] = []
        for root in roots {
            let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.hasPrefix("com.apple.") else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(url: url, name: name, bundleID: id))
            }
        }
        var seen: Set<String> = []
        return apps.filter { seen.insert($0.bundleID).inserted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func app(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(url: url, name: name, bundleID: id)
    }
}
