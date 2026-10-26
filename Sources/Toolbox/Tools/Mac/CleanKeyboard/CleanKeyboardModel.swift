import AppKit
import Observation
import SwiftUI

@MainActor
protocol CleaningOverlay: AnyObject {
    func show(model: CleanKeyboardModel)
    func hide()
}

@MainActor @Observable
final class CleanKeyboardModel {
    static let shared = CleanKeyboardModel()

    enum State: Equatable {
        case idle
        case cleaning(until: Date)
        case needsPermission
    }

    static let durations = [30, 60, 120]

    private(set) var state = State.idle
    var seconds = 60

    private let blocker: KeyboardBlocker
    private let overlay: CleaningOverlay
    private let now: () -> Date
    private var timer: Task<Void, Never>?

    init(blocker: KeyboardBlocker = EventTapKeyboardBlocker(), overlay: CleaningOverlay? = nil, now: @escaping () -> Date = Date.init) {
        self.blocker = blocker
        self.overlay = overlay ?? ScreenOverlay()
        self.now = now
    }

    var isCleaning: Bool { if case .cleaning = state { true } else { false } }

    func remaining(at date: Date) -> TimeInterval {
        if case .cleaning(let until) = state { max(0, until.timeIntervalSince(date)) } else { 0 }
    }

    func start() {
        guard !isCleaning else { return }
        guard blocker.start() else {
            state = .needsPermission
            AccessibilityAccess.prompt()
            return
        }
        let end = now().addingTimeInterval(TimeInterval(seconds))
        state = .cleaning(until: end)
        overlay.show(model: self)
        timer = Task { [weak self] in
            while let self, !Task.isCancelled {
                let left = end.timeIntervalSince(self.now())
                if left <= 0 { self.stop(); return }
                try? await Task.sleep(for: .milliseconds(min(left * 1000, 250)))
            }
        }
        Log.info("Keyboard cleaning started", category: "cleankeyboard", ["seconds": String(seconds)])
    }

    /// Always ends with the keyboard working again.
    func stop() {
        timer?.cancel()
        timer = nil
        blocker.stop()
        overlay.hide()
        if state != .needsPermission { state = .idle }
    }

    func recheckPermission() {
        if state == .needsPermission && AccessibilityAccess.isGranted { state = .idle }
    }
}

// MARK: Screen overlay

/// Dims every screen and shows the countdown with a Done button on the main one.
@MainActor
final class ScreenOverlay: CleaningOverlay {
    private var windows: [NSWindow] = []

    private final class Window: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    func show(model: CleanKeyboardModel) {
        hide()
        for (index, screen) in NSScreen.screens.enumerated() {
            let window = Window(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            let isMain = screen == NSScreen.main || (NSScreen.main == nil && index == 0)
            window.ignoresMouseEvents = !isMain
            window.contentView = NSHostingView(rootView: CleaningOverlayView(model: model, showsControls: isMain))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            if isMain { window.makeKey() }
            windows.append(window)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = []
    }
}

struct CleaningOverlayView: View {
    let model: CleanKeyboardModel
    let showsControls: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
            if showsControls {
                VStack(spacing: 18) {
                    Image(systemName: "keyboard").font(.system(size: 54)).foregroundStyle(.white.opacity(0.85))
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        Text(KeepAwakeModel.format(model.remaining(at: context.date)))
                            .font(.system(size: 76, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                    }
                    Text("The keyboard is paused. Wipe the keys, then click Done.").font(.title3).foregroundStyle(.white.opacity(0.85))
                    Button("Done") { model.stop() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .ignoresSafeArea()
    }
}
