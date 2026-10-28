import SwiftUI

/// The image with its regions on top. Drag over empty space to cover something new, drag a region to move it, drag its
/// sides or corners to resize it. The picture shown is already redacted, so what you see is what is saved.
struct RedactCanvas: View {
    let image: CGImage?
    let pixelSize: PixelSize
    let regions: [RedactImageModel.Region]
    let selectedID: UUID?
    var isEnabled = true
    let onSelect: (UUID?) -> Void
    let onCreate: (CGRect) -> UUID?
    let onChange: (UUID, CGRect) -> Void

    /// What the current drag is doing, decided where it started.
    private enum Session {
        case create(start: CGPoint, id: UUID?)
        case move(id: UUID, original: CGRect, start: CGPoint)
        /// `grab` is how far inside the side the drag began, so the side does not jump to the pointer.
        case resize(id: UUID, edges: RedactEdges, original: CGRect, grab: CGSize)
    }

    @State private var session: Session?

    var body: some View {
        GeometryReader { geo in
            let size = fit(in: geo.size)
            ZStack {
                picture(size)
                ForEach(regions) { region in outline(region, size: size) }
                if isEnabled, let selected = regions.first(where: { $0.id == selectedID }) { grips(for: selected.rect, size: size) }
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(drag(size))
                    .onContinuousHover { phase in
                        guard isEnabled else { return }
                        switch phase {
                        case .active(let point): cursor(at: point, size: size).set()
                        case .ended: NSCursor.arrow.set()
                        }
                    }
            }
            .frame(width: size.width, height: size.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    // MARK: Drawing

    @ViewBuilder private func picture(_ size: CGSize) -> some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: size.width, height: size.height)
        } else {
            Rectangle().fill(Theme.card).overlay(ProgressView().controlSize(.small))
        }
    }

    private func outline(_ region: RedactImageModel.Region, size: CGSize) -> some View {
        let r = screen(region.rect, size)
        let selected = region.id == selectedID
        return Rectangle()
            .strokeBorder(Theme.accent, lineWidth: selected ? 2 : 1.25)
            .background(selected ? Theme.accent.opacity(0.12) : .clear)
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }

    private func grips(for rect: CGRect, size: CGSize) -> some View {
        let r = screen(rect, size)
        let points = [r.minX, r.midX, r.maxX].flatMap { x in [r.minY, r.midY, r.maxY].map { CGPoint(x: x, y: $0) } }
            .filter { !($0.x == r.midX && $0.y == r.midY) }
        return ZStack {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(point)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Dragging

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled, size.width > 0, size.height > 0 else { return }
                if session == nil { begin(at: normalized(value.startLocation, size), size: size) }
                update(to: normalized(value.location, size), size: size)
            }
            .onEnded { _ in session = nil }
    }

    /// A press on a region side resizes it, on a region moves it, and on empty space starts a new one.
    private func begin(at start: CGPoint, size: CGSize) {
        switch RedactImage.hit(at: start, in: regions.map { ($0.id, $0.rect) }, size: size) {
        case .body(let id):
            onSelect(id)
            session = .move(id: id, original: rect(of: id), start: start)
        case .edge(let id, let edges):
            onSelect(id)
            let original = rect(of: id)
            let grab = CGSize(width: edges.contains(.left) ? start.x - original.minX : edges.contains(.right) ? start.x - original.maxX : 0,
                              height: edges.contains(.top) ? start.y - original.minY : edges.contains(.bottom) ? start.y - original.maxY : 0)
            session = .resize(id: id, edges: edges, original: original, grab: grab)
        case nil:
            onSelect(nil)
            session = .create(start: start, id: nil)
        }
    }

    private func update(to point: CGPoint, size: CGSize) {
        switch session {
        case .create(let start, let id)?:
            if let id {
                onChange(id, RedactImage.rect(from: start, to: point))
            } else if abs(point.x - start.x) * size.width >= 3 || abs(point.y - start.y) * size.height >= 3 {
                // A plain click only deselects; the region appears once the pointer has really moved.
                session = .create(start: start, id: onCreate(RedactImage.rect(from: start, to: point)))
            }
        case .move(let id, let original, let start)?:
            onChange(id, RedactImage.moved(original, by: CGSize(width: point.x - start.x, height: point.y - start.y)))
        case .resize(let id, let edges, let original, let grab)?:
            onChange(id, RedactImage.resized(original, edges: edges, to: CGPoint(x: point.x - grab.width, y: point.y - grab.height)))
        case nil:
            break
        }
    }

    private func cursor(at point: CGPoint, size: CGSize) -> NSCursor {
        switch RedactImage.hit(at: normalized(point, size), in: regions.map { ($0.id, $0.rect) }, size: size) {
        case .body?: return .openHand
        case .edge(_, let edges)?:
            let horizontal = edges.contains(.left) || edges.contains(.right), vertical = edges.contains(.top) || edges.contains(.bottom)
            return horizontal && vertical ? .crosshair : horizontal ? .resizeLeftRight : .resizeUpDown
        case nil: return .crosshair
        }
    }

    // MARK: Geometry

    private func rect(of id: UUID) -> CGRect { regions.first { $0.id == id }?.rect ?? .zero }

    private func normalized(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }

    private func screen(_ rect: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }

    /// The image's size on screen: as large as fits, with its own proportions.
    private func fit(in canvas: CGSize) -> CGSize {
        let (w, h) = (CGFloat(max(pixelSize.width, 1)), CGFloat(max(pixelSize.height, 1)))
        let scale = min(max(canvas.width, 1) / w, max(canvas.height, 1) / h)
        return CGSize(width: w * scale, height: h * scale)
    }
}
