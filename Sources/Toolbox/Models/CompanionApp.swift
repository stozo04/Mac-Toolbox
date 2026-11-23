import AppKit

/// A separate, free app that does a category's work better than a Toolbox tool would. Its card opens the app when it is
/// installed and otherwise shows where to get it.
enum CompanionApp: String, CaseIterable, Hashable {
    case folio
    case scarlet

    var name: String {
        switch self {
        case .folio: "Folio"
        case .scarlet: "Scarlet"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .folio: "app.folio.reader"
        case .scarlet: "com.forwardfuture.scarlet"
        }
    }

    var pitch: String {
        switch self {
        case .folio:
            "A free, open-source PDF reader and editor: read, highlight, annotate, sign, edit text and images, and turn Word documents into PDFs."
        case .scarlet:
            "A free, open-source AI video editor: tell Claude Code or Codex what to change, by voice, in writing or by drawing on a frame, and hear the edit in seconds."
        }
    }

    var downloadPage: URL {
        switch self {
        // Folio's source repository publishes no releases; its builds live in a separate repository.
        case .folio: URL(string: "https://github.com/mberman84/folio-releases/releases/latest")!
        case .scarlet: URL(string: "https://github.com/Forward-Future/scarlet/releases/latest")!
        }
    }
}

/// Finds and opens companion apps through Launch Services.
struct CompanionApps {
    var locate: (_ bundleIdentifier: String) -> URL?
    var launch: (_ appURL: URL) -> Void

    static let system = CompanionApps(
        locate: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        launch: { appURL in
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier ?? "unknown"
                    Log.error("Could not open \(appURL.lastPathComponent)", category: "companion",
                              Log.details(error, file: appURL, ["bundle_id": bundleIdentifier]))
                }
            }
        }
    )

    func installedURL(of app: CompanionApp) -> URL? { locate(app.bundleIdentifier) }

    /// Opens the app and returns true, or returns false when it is not installed.
    @discardableResult
    func open(_ app: CompanionApp) -> Bool {
        guard let url = installedURL(of: app) else { return false }
        launch(url)
        return true
    }
}
