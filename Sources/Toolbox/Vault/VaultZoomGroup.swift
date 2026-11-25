import ImageIO
import SwiftUI

/// Photos on the comparison screen, fitted into equal boxes so they show at the same size. Click and hold on any of
/// them zooms them all to the same spot, at the largest photo's own pixels; dragging while holding moves the spot.
@MainActor
@Observable
final class VaultZoomGroup {
    /// The spot under the pointer, from 0 to 1 across each box. Nil when not zoomed.
    private(set) var spot: UnitPoint?
    private(set) var largestWidth: CGFloat = 0

    private static let leastZoom: CGFloat = 2

    func note(pixelWidth: CGFloat) {
        largestWidth = max(largestWidth, pixelWidth)
    }

    func hold(at point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        spot = UnitPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }

    func release() { spot = nil }

    func reset() {
        spot = nil
        largestWidth = 0
    }

    func scale(forBoxWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return Self.leastZoom }
        return max(largestWidth / width, Self.leastZoom)
    }

    /// One photo, decoded with ImageIO straight from its file: no preview caches are written outside the vault.
    struct Pane: View {
        let url: URL
        let zoom: VaultZoomGroup
        @State private var image: CGImage?

        var body: some View {
            GeometryReader { box in
                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(width: box.size.width, height: box.size.height)
                            .scaleEffect(zoom.spot == nil ? 1 : zoom.scale(forBoxWidth: box.size.width), anchor: zoom.spot ?? .center)
                    } else {
                        ProgressView().frame(width: box.size.width, height: box.size.height)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { zoom.hold(at: $0.location, in: box.size) }
                    .onEnded { _ in zoom.release() })
            }
            .help("Click and hold to zoom every photo to this spot")
            .task(id: url) {
                let decoded = await Task.detached(priority: .userInitiated) { [url] in
                    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { source in
                        CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                    }
                }.value
                image = decoded
                if let decoded { zoom.note(pixelWidth: CGFloat(decoded.width)) }
            }
        }
    }
}
