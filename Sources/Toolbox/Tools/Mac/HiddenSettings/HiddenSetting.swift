import Foundation

/// One switch, slider or menu that maps to a macOS preference.
struct HiddenSetting: Identifiable {
    enum Kind {
        /// `inverted` flips the stored value, for keys that are named the opposite way round ("disable-shadow").
        case toggle(defaultStored: Bool, inverted: Bool)
        /// A number of seconds; nothing stored means the system default.
        case slider(range: ClosedRange<Double>)
        case choice([String], defaultStored: String)
        case folder(defaultPath: String)
    }

    enum Group: String, CaseIterable {
        case dock = "Dock", finder = "Finder", screenshots = "Screenshots", files = "Files", textEdit = "TextEdit"

        var restarts: RestartTarget? {
            switch self {
            case .dock: .dock
            case .finder, .files: .finder
            case .screenshots: .systemUIServer
            case .textEdit: nil
            }
        }
        var symbol: String {
            switch self {
            case .dock: "dock.rectangle"
            case .finder: "folder"
            case .screenshots: "camera.viewfinder"
            case .files: "externaldrive"
            case .textEdit: "doc.text"
            }
        }
        var footnote: String? {
            switch self {
            case .finder: "Finder windows close and reopen."
            case .textEdit: "Applies the next time TextEdit opens."
            default: nil
            }
        }
    }

    let id: String
    let group: Group
    let title: String
    var subtitle: String?
    let key: DefaultsKey
    let kind: Kind

    private static func key(_ domain: String, _ name: String) -> DefaultsKey { DefaultsKey(domain: domain, name: name) }

    static let all: [HiddenSetting] = [
        HiddenSetting(id: "dock.autohide", group: .dock, title: "Hide the Dock automatically",
                      key: key("com.apple.dock", "autohide"), kind: .toggle(defaultStored: false, inverted: false)),
        HiddenSetting(id: "dock.delay", group: .dock, title: "Delay before it appears", subtitle: "0 shows it the moment you reach the edge.",
                      key: key("com.apple.dock", "autohide-delay"), kind: .slider(range: 0...2)),
        HiddenSetting(id: "dock.speed", group: .dock, title: "Slide animation length", subtitle: "0 makes it appear instantly.",
                      key: key("com.apple.dock", "autohide-time-modifier"), kind: .slider(range: 0...2)),
        HiddenSetting(id: "dock.openOnly", group: .dock, title: "Show only open apps", subtitle: "Hides apps you've kept in the Dock until you open them.",
                      key: key("com.apple.dock", "static-only"), kind: .toggle(defaultStored: false, inverted: false)),
        HiddenSetting(id: "dock.recents", group: .dock, title: "Show recent apps",
                      key: key("com.apple.dock", "show-recents"), kind: .toggle(defaultStored: true, inverted: false)),

        HiddenSetting(id: "finder.hidden", group: .finder, title: "Show hidden files", subtitle: "⇧⌘. switches this in Finder too.",
                      key: key("com.apple.finder", "AppleShowAllFiles"), kind: .toggle(defaultStored: false, inverted: false)),
        HiddenSetting(id: "finder.extensions", group: .finder, title: "Show all file extensions",
                      key: key("NSGlobalDomain", "AppleShowAllExtensions"), kind: .toggle(defaultStored: false, inverted: false)),
        HiddenSetting(id: "finder.path", group: .finder, title: "Show the path bar",
                      key: key("com.apple.finder", "ShowPathbar"), kind: .toggle(defaultStored: false, inverted: false)),
        HiddenSetting(id: "finder.status", group: .finder, title: "Show the status bar",
                      key: key("com.apple.finder", "ShowStatusBar"), kind: .toggle(defaultStored: false, inverted: false)),
        HiddenSetting(id: "finder.foldersFirst", group: .finder, title: "Keep folders on top",
                      key: key("com.apple.finder", "_FXSortFoldersFirst"), kind: .toggle(defaultStored: false, inverted: false)),

        HiddenSetting(id: "shots.format", group: .screenshots, title: "Format",
                      key: key("com.apple.screencapture", "type"), kind: .choice(["png", "jpg", "pdf", "tiff", "gif", "heic"], defaultStored: "png")),
        HiddenSetting(id: "shots.folder", group: .screenshots, title: "Save to",
                      key: key("com.apple.screencapture", "location"), kind: .folder(defaultPath: "~/Desktop")),
        HiddenSetting(id: "shots.shadow", group: .screenshots, title: "Shadow on window screenshots",
                      key: key("com.apple.screencapture", "disable-shadow"), kind: .toggle(defaultStored: false, inverted: true)),
        HiddenSetting(id: "shots.thumbnail", group: .screenshots, title: "Floating thumbnail", subtitle: "Off saves screenshots straight away.",
                      key: key("com.apple.screencapture", "show-thumbnail"), kind: .toggle(defaultStored: true, inverted: false)),

        HiddenSetting(id: "files.network", group: .files, title: "No .DS_Store on network drives", subtitle: "Stops Finder leaving hidden files on shared folders.",
                      key: key("com.apple.desktopservices", "DSDontWriteNetworkStores"), kind: .toggle(defaultStored: false, inverted: false)),
        HiddenSetting(id: "files.usb", group: .files, title: "No .DS_Store on USB drives",
                      key: key("com.apple.desktopservices", "DSDontWriteUSBStores"), kind: .toggle(defaultStored: false, inverted: false)),

        HiddenSetting(id: "textedit.plain", group: .textEdit, title: "New documents are plain text",
                      key: key("com.apple.TextEdit", "RichText"), kind: .toggle(defaultStored: true, inverted: true)),
    ]

    static func settings(in group: Group) -> [HiddenSetting] { all.filter { $0.group == group } }
}
