import Darwin
import Foundation

/// The apps installed on this Mac, for telling which one a model belongs to.
struct AppIndex {
    struct Entry {
        var name: String
        var url: URL
        var bundleID: String?
        /// Normalized names found at the top of its Resources and Frameworks folders (an SDK built into the app shows up here).
        var embedded: [String]
    }

    var entries: [Entry]

    static let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]

    static func build(home: URL = FileManager.default.homeDirectoryForCurrentUser, folders: [URL]? = nil) -> AppIndex {
        let fm = FileManager.default
        let places = folders ?? (Self.folders.map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")])
        var entries: [Entry] = []
        for folder in places {
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] where url.pathExtension == "app" {
                let contents = url.appendingPathComponent("Contents")
                var embedded: [String] = []
                for sub in ["Resources", "Frameworks", "PlugIns"] {
                    embedded += ((try? fm.contentsOfDirectory(atPath: contents.appendingPathComponent(sub).path)) ?? []).map(normalize)
                }
                entries.append(Entry(name: url.deletingPathExtension().lastPathComponent, url: url,
                                     bundleID: Bundle(url: url)?.bundleIdentifier, embedded: embedded))
            }
        }
        return AppIndex(entries: entries)
    }

    static func normalize(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The apps behind a folder name such as "DigUp", "Google Chrome", "com.abdurrahim.DigUp" or an SDK like "FluidAudio".
    func apps(forOwner owner: String) -> [AssociatedApp] {
        let key = Self.normalize(owner)
        guard !key.isEmpty else { return [] }
        var matches = entries.filter { Self.normalize($0.name) == key || $0.bundleID?.lowercased() == owner.lowercased() }
        if matches.isEmpty, key.count >= 5 {
            matches = entries.filter { entry in entry.embedded.contains { $0.contains(key) } }
        }
        if matches.isEmpty {
            if owner.hasPrefix("Apple ") { return [AssociatedApp(name: "macOS (\(owner.dropFirst("Apple ".count)))", bundleURL: nil, note: AssociatedApp.builtIntoMacOS)] }
            return [AssociatedApp(name: owner, bundleURL: nil, note: "no app of that name found here")]
        }
        return matches.map { AssociatedApp(name: $0.name, bundleURL: $0.url) }
    }

    /// The app a running program belongs to, by the path of its executable.
    func app(forExecutable path: String, fallbackName: String) -> AssociatedApp {
        // The outermost app: a helper inside DigUp.app is DigUp, not the updater nested in it.
        if let range = path.range(of: ".app/") {
            let bundle = URL(fileURLWithPath: String(path[..<range.upperBound].dropLast()))
            return AssociatedApp(name: bundle.deletingPathExtension().lastPathComponent, bundleURL: bundle, inUse: true)
        }
        return AssociatedApp(name: fallbackName, bundleURL: nil, inUse: true)
    }
}

enum ModelAssociations {
    /// Fills in `apps` for every model: the owner's apps first, then whatever has the file open now.
    static func apply(to models: [InstalledModel], index: AppIndex) async -> [InstalledModel] {
        let files = models.filter { $0.parts == 1 && !$0.url.hasDirectoryPath && FileManager.default.fileExists(atPath: $0.url.path) && !isFolder($0.url) }.map(\.url.path)
        let users = await runningUsers(of: files, index: index)
        return models.map { model in
            var m = model
            var apps = model.owner.map(index.apps(forOwner:)) ?? []
            for user in users[model.url.path] ?? [] {
                if let i = apps.firstIndex(where: { $0.bundleURL != nil && $0.bundleURL == user.bundleURL || $0.name == user.name }) {
                    apps[i].inUse = true
                } else {
                    apps.append(user)
                }
            }
            m.apps = apps
            return m
        }
    }

    private static func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

    /// Programs that have each file open (lsof also sees files a program has mapped into memory, how models are usually loaded).
    static func runningUsers(of paths: [String], index: AppIndex) async -> [String: [AssociatedApp]] {
        guard !paths.isEmpty, let result = try? await Shell.run("/usr/sbin/lsof", ["-nP", "-F", "pcn", "--"] + paths, timeout: 8) else { return [:] }
        return parse(lsof: result.out, index: index)
    }

    static func parse(lsof output: String, index: AppIndex) -> [String: [AssociatedApp]] {
        var users: [String: [AssociatedApp]] = [:]
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                let app = index.app(forExecutable: executablePath(pid) ?? "", fallbackName: command)
                if !(users[value] ?? []).contains(app) { users[value, default: []].append(app) }
            default: break
            }
        }
        return users
    }

    private static func executablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
