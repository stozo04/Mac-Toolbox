import SwiftUI

/// The photo at its new size, with grips on every side and corner to pull it bigger or smaller.
/// The picture stays centered, so a grip always sits under the cursor while it is dragged.
struct ResizeCanvas: View {
    let original: PixelSize
    let output: PixelSize
    let image: CGImage?
    var isEnabled = true
    /// A grip moved: where the cursor puts the photo's width and height, in the photo's own pixels.
    let onDrag: (ResizeHandle, Double, Double) -> Void

    /// Fixed while a grip is held, so the picture does not rescale under the cursor.
    @State private var frozenScale: CGFloat?

    private let space = "resize-canvas"
    private let margin: CGFloat = 40
    /// How much bigger than the original the canvas has room for, so there is space to pull it larger.
    private let headroom = 1.5

    var body: some View {
        GeometryReader { geo in
            let scale = frozenScale ?? fitScale(in: geo.size)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let size = CGSize(width: CGFloat(output.width) * scale, height: CGFloat(output.height) * scale)
            ZStack {
                picture(size).position(center)
                // Where the photo started, drawn over it so growing shows how far it has come.
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .frame(width: CGFloat(original.width) * scale, height: CGFloat(original.height) * scale)
                    .position(center)
                    .allowsHitTesting(false)
                if isEnabled {
                    ForEach(ResizeHandle.allCases, id: \.self) { handle in
                        grip(handle, size: size, center: center, scale: scale)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: space)
            .clipped()
            .overlay(alignment: .top) { readout.padding(.top, 10) }
            .overlay(alignment: .bottom) {
                if isEnabled {
                    Text("Drag a side or corner to resize").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 10)
                }
            }
        }
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Drawing

    @ViewBuilder private func picture(_ size: CGSize) -> some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
                .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        } else {
            Rectangle().fill(Theme.card)
                .frame(width: size.width, height: size.height)
                .overlay(ProgressView().controlSize(.small))
                .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5))
        }
    }

    private var readout: some View {
        let percent = Int((Double(output.longest) / Double(max(original.longest, 1)) * 100).rounded())
        return HStack(spacing: 6) {
            Text("\(original.width) × \(original.height)").foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
            Text("\(output.width) × \(output.height) px").fontWeight(.semibold)
            Text("· \(percent)%").foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: Grips

    private func grip(_ handle: ResizeHandle, size: CGSize, center: CGPoint, scale: CGFloat) -> some View {
        let isCorner = handle.dx != 0 && handle.dy != 0
        let at = CGPoint(x: center.x + CGFloat(handle.dx) * size.width / 2, y: center.y + CGFloat(handle.dy) * size.height / 2)
        // A side can be grabbed anywhere along it (apart from the corners); a corner only near its point.
        let hit = CGSize(width: handle.dx == 0 ? max(size.width - 24, 18) : 18, height: handle.dy == 0 ? max(size.height - 24, 18) : 18)
        return ZStack {
            Rectangle().fill(Color.clear).frame(width: hit.width, height: hit.height).contentShape(Rectangle())
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(.white)
                .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
                .frame(width: 10, height: 10)
                .allowsHitTesting(false)
        }
        .position(at)
        .zIndex(isCorner ? 2 : 1)
        .resizeCursor(handle)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { drag in
                    let s = frozenScale ?? scale
                    frozenScale = s
                    // Distance from the center to the cursor, doubled because the picture grows on both sides.
                    let w = handle.dx == 0 ? Double(output.width) : Double(2 * CGFloat(handle.dx) * (drag.location.x - center.x) / s)
                    let h = handle.dy == 0 ? Double(output.height) : Double(2 * CGFloat(handle.dy) * (drag.location.y - center.y) / s)
                    onDrag(handle, max(w, 1), max(h, 1))
                }
                .onEnded { _ in withAnimation(.easeOut(duration: 0.2)) { frozenScale = nil } }
        )
    }

    /// Points per pixel: the original (with room to grow) or the new size, whichever is bigger, fits the canvas.
    private func fitScale(in canvas: CGSize) -> CGFloat {
        let room = CGSize(width: max(canvas.width - 2 * margin, 40), height: max(canvas.height - 2 * margin, 40))
        let w = max(Double(original.width) * headroom, Double(output.width))
        let h = max(Double(original.height) * headroom, Double(output.height))
        return CGFloat(min(Double(room.width) / w, Double(room.height) / h))
    }
}

// MARK: Cursor

private extension ResizeHandle {
    @available(macOS 15, *)
    var position: FrameResizePosition {
        switch self {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .left: .leading
        case .right: .trailing
        case .bottomLeft: .bottomLeading
        case .bottom: .bottom
        case .bottomRight: .bottomTrailing
        }
    }

    var cursor: NSCursor {
        switch (dx != 0, dy != 0) {
        case (true, false): .resizeLeftRight
        case (false, true): .resizeUpDown
        default: .crosshair
        }
    }
}

private extension View {
    /// The resize arrow for this grip: diagonal arrows on corners need macOS 15; earlier systems get a plain pointer shape.
    @ViewBuilder func resizeCursor(_ handle: ResizeHandle) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.frameResize(position: handle.position))
        } else {
            onHover { inside in if inside { handle.cursor.push() } else { NSCursor.pop() } }
        }
    }
}
