import AppKit
import ScreenCaptureKit

struct DisplaySource: Identifiable {
    let display: SCDisplay
    let name: String
    var thumbnail: NSImage?
    var id: CGDirectDisplayID { display.displayID }
    var sizeText: String { "\(display.width) × \(display.height)" }
    var screen: NSScreen? { NSScreen.screen(for: display.displayID) }
}

struct WindowSource: Identifiable {
    let window: SCWindow
    let app: String
    let title: String
    var thumbnail: NSImage?
    var id: CGWindowID { window.windowID }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? { screens.first { $0.displayID == id } }
}

enum CaptureSources {
    struct Listing {
        var displays: [DisplaySource]
        var windows: [WindowSource]
    }

    /// Throws when Screen Recording is not allowed.
    static func load() async throws -> Listing {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = content.displays.map { d in
            DisplaySource(display: d, name: NSScreen.screen(for: d.displayID)?.localizedName ?? "Display \(d.displayID)")
        }
        let windows = content.windows
            .filter { w in
                w.windowLayer == 0 && w.isOnScreen && w.frame.width >= 100 && w.frame.height >= 60
                    && w.owningApplication?.processID != ownPID
                    && !(w.owningApplication?.applicationName ?? "").isEmpty
            }
            .map { WindowSource(window: $0, app: $0.owningApplication?.applicationName ?? "", title: $0.title ?? "") }
            .sorted { ($0.app, $0.title) < ($1.app, $1.title) }
        return Listing(displays: displays, windows: windows)
    }

    static func thumbnail(display: SCDisplay) async -> NSImage? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return await thumbnail(filter: filter, aspect: CGFloat(display.width) / CGFloat(max(display.height, 1)))
    }

    static func thumbnail(window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return await thumbnail(filter: filter, aspect: window.frame.width / max(window.frame.height, 1))
    }

    private static func thumbnail(filter: SCContentFilter, aspect: CGFloat) async -> NSImage? {
        let config = SCStreamConfiguration()
        config.width = 480
        config.height = max(1, Int(480 / max(aspect, 0.1)))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Where the recording sits on screen in global points (origin bottom left), for placing click rings.
    static func captureRect(for target: RecordingTarget) -> CGRect? {
        switch target {
        case .display(let d):
            return NSScreen.screen(for: d.displayID)?.frame
        case .area(let d, let rect):
            guard let frame = NSScreen.screen(for: d.displayID)?.frame else { return nil }
            return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        case .window(let w):
            // The window may have moved since the list was made, so ask the window server.
            guard let primary = NSScreen.screens.first,
                  let info = (CGWindowListCreateDescriptionFromArray([w.windowID] as CFArray) as? [[CFString: Any]])?.first,
                  let boundsDict = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return CGRect(x: bounds.minX, y: primary.frame.height - bounds.maxY, width: bounds.width, height: bounds.height)
        }
    }
}
