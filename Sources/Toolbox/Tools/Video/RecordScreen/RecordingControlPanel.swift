import AppKit
import SwiftUI

/// The small floating bar with the timer and Stop button. It is hidden from screen capture,
/// so it never ends up in the recording.
@MainActor
final class RecordingControlPanel {
    private var panel: NSPanel?

    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func show(model: RecordScreenModel, on screen: NSScreen?) {
        let host = NSHostingView(rootView: RecordingControlBar(model: model))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct RecordingControlBar: View {
    let model: RecordScreenModel

    var body: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .countdown(let n):
                Text("\(n)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    .frame(width: 30)
                Text("Starting").font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { model.cancelCountdown() }
                    .buttonStyle(.bordered).controlSize(.small)
            default:
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(RecordingGeometry.clock(model.elapsed)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                Button { model.stop() } label: {
                    Label("Stop", systemImage: "stop.fill").font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                .disabled(model.phase != .recording)
            }
        }
        .frame(width: 180)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .fixedSize()
    }
}
