import AppKit
import ScreenCaptureKit

/// Capture Area: dim the screen, drag out a part of it, and get that part as a picture.
@MainActor
enum AnnotateCapture {
    enum Failure: LocalizedError {
        case noAccess
        case failed

        var errorDescription: String? {
            switch self {
            case .noAccess: "Allow Toolbox to record the screen in System Settings > Privacy & Security > Screen Recording, then try again."
            case .failed: "The screen could not be captured."
            }
        }
    }

    /// The picture of the area the user drags out, or nil if they cancel with Esc.
    static func area() async throws -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw Failure.noAccess
        }
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        guard let displayID = screen.displayID else { throw Failure.failed }

        // Toolbox steps aside so the picture shows what is behind it, then comes back.
        let hidden = NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }
        hidden.forEach { $0.alphaValue = 0 }
        defer {
            hidden.forEach { $0.alphaValue = 1 }
            NSApp.activate(ignoringOtherApps: true)
        }
        guard let rect = await AreaSelector.select(on: screen) else { return nil }
        // Give the window server a moment to take the dimming layer off the screen.
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard let display = try await SCShareableContent.current.displays.first(where: { $0.displayID == displayID }) else { throw Failure.failed }
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = max(1, Int((rect.width * screen.backingScaleFactor).rounded()))
        config.height = max(1, Int((rect.height * screen.backingScaleFactor).rounded()))
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
