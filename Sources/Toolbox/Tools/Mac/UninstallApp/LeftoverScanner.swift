import AppKit

struct Leftover: Identifiable, Hashable {
    enum Confidence: String {
        /// The name is the app's identifier: certainly this app's.
        case exact
        /// Starts with the identifier, e.g. a helper or a related component.
        case related
        /// Only shares the app's display name: could belong to something else.
        case nameOnly
    }

    let url: URL
    let place: String
    let bytes: Int64
    let confidence: Confidence
    let isApp: Bool
    var id: URL { url }
}

enum LeftoverScanner {
    /// Folders inside ~/Library where apps leave files.
    static let places = ["Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers",
                         "Saved Application State", "Logs", "WebKit", "HTTPStorages", "Cookies", "LaunchAgents", "Application Scripts"]

    /// Why an item in one of those folders counts as this app's, or nil when it doesn't.
    static func confidence(of entry: String, place: String, bundleID: String, appName: String) -> Leftover.Confidence? {
        var base = entry
        for ext in [".plist", ".savedState", ".binarycookies", ".sfl2", ".sfl3", ".lockfile"] where base.hasSuffix(ext) { base = String(base.dropLast(ext.count)) }
        let id = bundleID.lowercased(), lower = base.lowercased()
        if lower == id { return .exact }
        if place == "Group Containers", lower.hasSuffix("." + id) { return .exact }
        if lower.hasPrefix(id + ".") { return .related }
        if !appName.isEmpty, ["Application Support", "Caches", "Logs"].contains(place), lower == appName.lowercased() { return .nameOnly }
        return nil
    }

    /// Apple's apps and system folders are never offered for removal.
    static func isProtected(bundleID: String, appURL: URL) -> Bool {
        bundleID.hasPrefix("com.apple.") || appURL.path.hasPrefix("/System/") || bundleID == Bundle.main.bundleIdentifier
    }

    static func scan(app: URL, bundleID: String, appName: String, library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")) -> [Leftover] {
        var found = [Leftover(url: app, place: "Application", bytes: DirectorySize.bytes(of: app), confidence: .exact, isApp: true)]
        for place in places {
            let folder = library.appendingPathComponent(place)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for entry in entries {
                guard let confidence = confidence(of: entry, place: place, bundleID: bundleID, appName: appName) else { continue }
                let url = folder.appendingPathComponent(entry)
                found.append(Leftover(url: url, place: place, bytes: DirectorySize.bytes(of: url), confidence: confidence, isApp: false))
            }
        }
        return found
    }
}
