import AppKit
import SwiftUI

struct WindowPresence: Equatable {
    let canBecomeMain: Bool
    let isVisible: Bool
    let isMinimized: Bool

    init(canBecomeMain: Bool, isVisible: Bool, isMinimized: Bool) {
        self.canBecomeMain = canBecomeMain
        self.isVisible = isVisible
        self.isMinimized = isMinimized
    }

    init(_ window: NSWindow) {
        self.init(canBecomeMain: window.canBecomeMain, isVisible: window.isVisible, isMinimized: window.isMiniaturized)
    }

    static func hasMainWindow(_ windows: [WindowPresence]) -> Bool {
        windows.contains { $0.isMinimized || ($0.canBecomeMain && $0.isVisible) }
    }
}

struct PendingWindowOpen {
    static let timeout: TimeInterval = 2
    private var requestedAt: Date?

    func isInFlight(at now: Date) -> Bool {
        guard let requestedAt else { return false }
        return now.timeIntervalSince(requestedAt) < Self.timeout
    }

    mutating func begin(at now: Date) { requestedAt = now }
    mutating func finish() { requestedAt = nil }
}

@MainActor
final class MainWindowReopener: NSObject, NSApplicationDelegate {
    static let windowID = "main"
    private var openMainWindow: (() -> Void)?
    private var pendingOpen = PendingWindowOpen()

    func mainWindowAppeared(opener: @escaping () -> Void) {
        openMainWindow = opener
        pendingOpen.finish()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let windows = sender.windows.map(WindowPresence.init)
        guard !sender.isHidden, !WindowPresence.hasMainWindow(windows), let openMainWindow else { return true }
        let now = Date()
        guard !pendingOpen.isInFlight(at: now) else { return false }
        Log.info("Reopening the main window after it was closed", category: "app")
        pendingOpen.begin(at: now)
        openMainWindow()
        return false
    }
}

private struct RegistersMainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let reopener: MainWindowReopener

    func body(content: Content) -> some View {
        content.onAppear {
            reopener.mainWindowAppeared { [openWindow] in openWindow(id: MainWindowReopener.windowID) }
        }
    }
}

extension View {
    func registersMainWindowOpener(_ reopener: MainWindowReopener) -> some View {
        modifier(RegistersMainWindowOpener(reopener: reopener))
    }
}
