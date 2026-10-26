import AppKit

/// Dims one screen and lets the user drag out the region to record.
@MainActor
enum AreaSelector {
    private static var active: NSWindow?

    /// Returns the region in points relative to the screen's top-left corner, or nil if cancelled.
    static func select(on screen: NSScreen) async -> CGRect? {
        await withCheckedContinuation { continuation in
            let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { rect in
                window.orderOut(nil)
                active = nil
                continuation.resume(returning: rect)
            }
            window.contentView = view
            active = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var selection: CGRect?
    private static let minimum: CGFloat = 32

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let selection { dim.append(NSBezierPath(rect: selection)); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()

        guard let selection else {
            drawLabel("Drag to choose an area. Esc to cancel.", at: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5
        border.stroke()
        drawLabel("\(Int(selection.width)) × \(Int(selection.height))", at: CGPoint(x: selection.midX, y: max(selection.minY - 18, 14)))
    }

    private func drawLabel(_ text: String, at center: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let string = NSAttributedString(string: text, attributes: attrs)
        let size = string.size()
        let box = CGRect(x: center.x - size.width / 2 - 8, y: center.y - size.height / 2 - 3, width: size.width + 16, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3))
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, selection.width >= Self.minimum, selection.height >= Self.minimum else {
            self.selection = nil
            anchor = nil
            needsDisplay = true
            return
        }
        // Flip to a top-left origin, which is what ScreenCaptureKit expects.
        onFinish?(CGRect(x: selection.minX.rounded(), y: (bounds.height - selection.maxY).rounded(),
                         width: selection.width.rounded(), height: selection.height.rounded()))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }
}
