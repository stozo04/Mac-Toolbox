import AppKit
import CoreVideo

/// Draws an expanding yellow ring into recorded frames wherever the mouse is clicked.
/// It paints the frames themselves rather than a screen overlay, so it also works for single-window capture.
final class ClickHighlighter {
    private struct Click { let x: CGFloat; let y: CGFloat; let time: CFTimeInterval }

    private static let duration: CFTimeInterval = 0.55

    private let captureRect: () -> CGRect?
    private let lock = NSLock()
    private var clicks: [Click] = []
    private var monitors: [Any] = []

    /// `captureRect` returns what is being recorded in global screen points (origin bottom left), looked up
    /// at click time so a window that moves is still tracked.
    init(captureRect: @escaping () -> CGRect?) { self.captureRect = captureRect }

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.record() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.record()
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func record() {
        let point = NSEvent.mouseLocation
        guard let rect = captureRect(), rect.width > 0, rect.height > 0 else { return }
        let x = (point.x - rect.minX) / rect.width, y = (point.y - rect.minY) / rect.height
        guard (0...1).contains(x), (0...1).contains(y) else { return }
        lock.lock(); defer { lock.unlock() }
        clicks.append(Click(x: x, y: y, time: CACurrentMediaTime()))
    }

    /// Paints any live rings onto a BGRA frame. Cheap when nothing was clicked.
    func draw(into frame: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        clicks.removeAll { now - $0.time > Self.duration }
        let live = clicks
        lock.unlock()
        guard !live.isEmpty else { return }

        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        guard let base = CVPixelBufferGetBaseAddress(frame),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(frame),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        // Sized from the frame height so rings look the same at 720p and at native resolution.
        let unit = CGFloat(height) / 1080
        for click in live {
            let t = CGFloat((now - click.time) / Self.duration)
            let center = CGPoint(x: click.x * CGFloat(width), y: click.y * CGFloat(height))
            let radius = (16 + 26 * t) * unit
            let alpha = 1 - t
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 0.35 * alpha))
            context.fillEllipse(in: circle)
            context.setStrokeColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 0.95 * alpha))
            context.setLineWidth(3 * unit)
            context.strokeEllipse(in: circle)
        }
    }
}
