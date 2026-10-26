import Foundation

/// A usual suspect for disk space: where it lives, how to describe it, and whether Toolbox may clear it.
struct SpaceHog: Identifiable {
    enum Clearing {
        /// Items inside can be moved to the Trash.
        case trash
        /// The items are already in the Trash; clearing deletes them for good.
        case emptyTrash
        /// Only the owning app should clear it.
        case notHere(String)
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let root: URL
    let clearing: Clearing
    /// The things inside that can be picked: the folder's children, unless a filter narrows them.
    let filter: (URL) -> Bool

    init(id: String, title: String, detail: String, symbol: String, root: URL, clearing: Clearing, filter: @escaping (URL) -> Bool = { _ in true }) {
        self.id = id; self.title = title; self.detail = detail; self.symbol = symbol; self.root = root; self.clearing = clearing; self.filter = filter
    }

    static func all(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> [SpaceHog] {
        let library = home.appendingPathComponent("Library")
        let cutoff = now.addingTimeInterval(-90 * 24 * 3600)
        return [
            SpaceHog(id: "simulators", title: "iOS Simulators",
                     detail: "Simulator devices and their app data. Remove unused ones from Xcode › Window › Devices and Simulators.",
                     symbol: "iphone.gen3", root: library.appendingPathComponent("Developer/CoreSimulator/Devices"),
                     clearing: .notHere("Remove simulators from Xcode › Window › Devices and Simulators.")),
            SpaceHog(id: "caches", title: "App Caches",
                     detail: "Files apps keep to start faster. Generally safe to remove: apps rebuild them, though some will feel slower at first.",
                     symbol: "tray.full", root: library.appendingPathComponent("Caches"), clearing: .trash,
                     filter: { $0.lastPathComponent != "Homebrew" }),
            SpaceHog(id: "homebrew", title: "Homebrew Downloads",
                     detail: "Downloaded installers Homebrew keeps after installing. Safe to remove.",
                     symbol: "shippingbox", root: library.appendingPathComponent("Caches/Homebrew/downloads"), clearing: .trash),
            SpaceHog(id: "docker", title: "Docker",
                     detail: "Docker's disk image with your images, containers and volumes. Clean it up from Docker itself.",
                     symbol: "cube", root: library.appendingPathComponent("Containers/com.docker.docker/Data/vms"),
                     clearing: .notHere("Use Docker's own “Clean up” or `docker system prune`.")),
            SpaceHog(id: "backups", title: "iPhone and iPad Backups",
                     detail: "Local backups made by Finder. Remove backups of devices you no longer have, or that are backed up to iCloud.",
                     symbol: "iphone.and.arrow.forward", root: library.appendingPathComponent("Application Support/MobileSync/Backup"), clearing: .trash),
            SpaceHog(id: "trash", title: "Trash", detail: "Files you've deleted. They still use space until you empty the Trash.",
                     symbol: "trash", root: home.appendingPathComponent(".Trash"), clearing: .emptyTrash),
            SpaceHog(id: "downloads", title: "Old Downloads", detail: "Items in Downloads you added more than 90 days ago.",
                     symbol: "arrow.down.circle", root: home.appendingPathComponent("Downloads"), clearing: .trash,
                     filter: { url in
                         let v = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
                         guard let added = v?.addedToDirectoryDate ?? v?.creationDate ?? v?.contentModificationDate else { return false }
                         return added < cutoff
                     }),
        ]
    }
}

struct HogItem: Identifiable, Hashable {
    let url: URL
    let bytes: Int64
    var id: URL { url }
}

struct HogResult: Equatable {
    var items: [HogItem]
    /// True when the folder exists but macOS did not let Toolbox read it.
    var needsAccess: Bool
    var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

enum StorageScanner {
    /// Sizes the pickable items of one hog. Slow for big folders: call off the main thread.
    static func measure(_ hog: SpaceHog) -> HogResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hog.root.path) else { return HogResult(items: [], needsAccess: false) }
        guard let names = try? fm.contentsOfDirectory(atPath: hog.root.path) else { return HogResult(items: [], needsAccess: true) }
        var items: [HogItem] = []
        for name in names where name != ".DS_Store" {
            if Task.isCancelled { break }
            let url = hog.root.appendingPathComponent(name)
            guard hog.filter(url) else { continue }
            items.append(HogItem(url: url, bytes: DirectorySize.bytes(of: url)))
        }
        return HogResult(items: items.sorted { $0.bytes > $1.bytes }, needsAccess: false)
    }

    struct DiskUsage: Equatable {
        var total: Int64
        var used: Int64
        var purgeable: Int64
        var free: Int64
    }

    static func diskUsage(of url: URL = URL(fileURLWithPath: "/")) -> DiskUsage? {
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacity else { return nil }
        let important = v.volumeAvailableCapacityForImportantUsage ?? Int64(free)
        let purgeable = max(0, important - Int64(free))
        return DiskUsage(total: Int64(total), used: max(0, Int64(total) - Int64(free) - purgeable), purgeable: purgeable, free: Int64(free))
    }
}

enum StorageCleaner {
    struct Outcome: Equatable {
        var freed: Int64 = 0
        var failures: [String] = []
    }

    /// An item is only touched if it really sits inside the hog's own folder, however it was named.
    static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") && !path.contains("/../")
    }

    static func clear(_ items: [HogItem], from hog: SpaceHog,
                      trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                      delete: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Outcome {
        var outcome = Outcome()
        for item in items {
            guard isInside(item.url, root: hog.root) else { outcome.failures.append(item.url.lastPathComponent); continue }
            do {
                switch hog.clearing {
                case .trash: try trash(item.url)
                case .emptyTrash: try delete(item.url)
                case .notHere: outcome.failures.append(item.url.lastPathComponent); continue
                }
                outcome.freed += item.bytes
            } catch {
                outcome.failures.append(item.url.lastPathComponent)
            }
        }
        return outcome
    }
}
