import AppKit
import Observation

@MainActor @Observable
final class UninstallAppModel {
    static let shared = UninstallAppModel()

    struct AppInfo: Equatable {
        let url: URL
        let name: String
        let bundleID: String
    }

    enum Phase: Equatable {
        case empty
        case scanning
        case ready
        case removing
        case done(moved: Int, bytes: Int64, failures: [String])
    }

    private(set) var app: AppInfo?
    private(set) var items: [Leftover] = []
    private(set) var phase = Phase.empty
    private(set) var message: String?
    var selection: Set<URL> = []

    private let library: URL
    private let trash: (URL) throws -> Void
    private let isRunning: (String) -> Bool

    init(library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"),
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         isRunning: @escaping (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
        self.library = library
        self.trash = trash
        self.isRunning = isRunning
    }

    var selectedBytes: Int64 { items.filter { selection.contains($0.url) }.reduce(0) { $0 + $1.bytes } }

    func load(_ url: URL) {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            message = "That isn't an app. Choose a file that ends in .app."
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        guard !LeftoverScanner.isProtected(bundleID: id, appURL: url) else {
            message = "“\(name)” is part of macOS or Toolbox and can't be removed here."
            return
        }
        message = nil
        app = AppInfo(url: url, name: name, bundleID: id)
        phase = .scanning
        let library = library
        Task {
            let found = await Task.detached { LeftoverScanner.scan(app: url, bundleID: id, appName: name, library: library) }.value
            guard app?.url == url else { return }
            items = found.sorted { ($0.isApp ? 1 : 0, $0.bytes) > ($1.isApp ? 1 : 0, $1.bytes) }
            // Only certain matches start ticked; look-alikes are left for the person to decide.
            selection = Set(items.filter { $0.confidence == .exact }.map(\.url))
            phase = .ready
        }
    }

    func toggle(_ item: Leftover) {
        if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
    }

    func close() { app = nil; items = []; selection = []; phase = .empty; message = nil }

    /// Moves the ticked items to the Trash. Nothing is deleted for good.
    func remove() {
        guard let app, phase == .ready else { return }
        if isRunning(app.bundleID) {
            message = "“\(app.name)” is open. Quit it first, then try again."
            return
        }
        message = nil
        phase = .removing
        var moved = 0, bytes: Int64 = 0
        var failures: [String] = []
        for item in items where selection.contains(item.url) {
            do {
                try trash(item.url)
                moved += 1
                bytes += item.bytes
            } catch {
                failures.append(item.url.lastPathComponent)
            }
        }
        phase = .done(moved: moved, bytes: bytes, failures: failures)
        Log.info("App removed", category: "uninstall", ["items": String(moved), "failed": String(failures.count)])
    }

    func confirmAndRemove() {
        guard let app else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(app.name)” and \(max(selection.count - 1, 0)) related item(s) to the Trash?"
        alert.informativeText = "\(ByteFormat.string(selectedBytes)) will be moved. You can put things back from the Trash until you empty it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { remove() }
    }
}
