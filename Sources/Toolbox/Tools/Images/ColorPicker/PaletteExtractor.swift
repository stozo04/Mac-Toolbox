import CoreGraphics
import Foundation
import ImageIO

/// One of an image's main colors and how much of the image it covers.
struct PaletteColor: Identifiable, Equatable {
    let color: RGBAColor
    /// 0...1 of the pixels that count (see-through pixels are left out).
    let share: Double
    var id: String { ColorFormat.hex.string(for: color, includeAlpha: false) }
}

/// Finds the main colors of an image: pixels are grouped by color, the groups are clustered
/// in OKLab (where distance matches what the eye sees), and near-twins are merged.
enum PaletteExtractor {
    /// Pixels fewer or more than this are scaled to fit before counting; plenty to find the main colors.
    static let sampleSize = 160
    /// The fewest colors asked for, and the most.
    static let countRange = 5...8
    /// Two colors closer than this (in OKLab) read as one, so they are merged while more than the fewest remain.
    static let mergeDistance = 0.04

    // MARK: Reading an image

    /// A small copy of the image at `url`, upright, for sampling. Nil when it cannot be read.
    static func sample(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Finding the colors

    /// The main colors of `image`, most common first. `count` is clamped to 5...8; an image with fewer
    /// distinct colors (a flat logo) gives fewer.
    static func colors(in image: CGImage, count: Int = 6) -> [PaletteColor] {
        guard let pixels = pixels(of: image) else { return [] }
        return colors(inPixels: pixels, count: count)
    }

    /// `pixels` is straight (not premultiplied) RGBA, four bytes each.
    static func colors(inPixels pixels: [UInt8], count: Int) -> [PaletteColor] {
        let k = min(countRange.upperBound, max(countRange.lowerBound, count))

        // Group by 5 bits per channel and keep each group's true average, so a pick is a color that is in the image.
        struct Bin { var r = 0.0, g = 0.0, b = 0.0, n = 0.0 }
        var bins: [Int: Bin] = [:]
        var total = 0.0
        var i = 0
        while i + 3 < pixels.count {
            defer { i += 4 }
            guard pixels[i + 3] >= 128 else { continue }
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            var bin = bins[key, default: Bin()]
            bin.r += Double(r); bin.g += Double(g); bin.b += Double(b); bin.n += 1
            bins[key] = bin
            total += 1
        }
        guard total > 0 else { return [] }

        // Sorted so the result never depends on dictionary order.
        let points: [(rgb: SIMD3<Double>, lab: SIMD3<Double>, weight: Double)] = bins.keys.sorted().map { key in
            let bin = bins[key]!
            let rgb = SIMD3(bin.r, bin.g, bin.b) / bin.n / 255
            let lab = RGBAColor(red: rgb.x, green: rgb.y, blue: rgb.z).oklab
            return (rgb, SIMD3(lab.l, lab.a, lab.b), bin.n)
        }

        // Start from the most common color, then keep adding the one farthest from all chosen so far.
        var centers: [SIMD3<Double>] = []
        var nearest = [Double](repeating: .infinity, count: points.count)
        for _ in 0..<min(k, points.count) {
            var pick = 0, best = -1.0
            for (index, point) in points.enumerated() {
                let score = centers.isEmpty ? point.weight : point.weight * nearest[index]
                if score > best { best = score; pick = index }
            }
            centers.append(points[pick].lab)
            for (index, point) in points.enumerated() {
                nearest[index] = min(nearest[index], squaredDistance(point.lab, points[pick].lab))
            }
        }

        // k-means, weighted by how many pixels each group holds.
        var assignment = [Int](repeating: 0, count: points.count)
        for _ in 0..<20 {
            var changed = false
            for (index, point) in points.enumerated() {
                var best = 0, bestDistance = Double.infinity
                for (c, center) in centers.enumerated() {
                    let d = squaredDistance(point.lab, center)
                    if d < bestDistance { bestDistance = d; best = c }
                }
                if assignment[index] != best { assignment[index] = best; changed = true }
            }
            var sums = [SIMD3<Double>](repeating: .zero, count: centers.count)
            var weights = [Double](repeating: 0, count: centers.count)
            for (index, point) in points.enumerated() {
                sums[assignment[index]] += point.lab * point.weight
                weights[assignment[index]] += point.weight
            }
            for c in centers.indices where weights[c] > 0 { centers[c] = sums[c] / weights[c] }
            if !changed { break }
        }

        // Each cluster's color is the average of its pixels' real colors.
        var clusters: [(rgb: SIMD3<Double>, weight: Double)] = []
        for c in centers.indices {
            var sum = SIMD3<Double>.zero, weight = 0.0
            for (index, point) in points.enumerated() where assignment[index] == c {
                sum += point.rgb * point.weight
                weight += point.weight
            }
            if weight > 0 { clusters.append((sum / weight, weight)) }
        }

        clusters = mergeTwins(clusters)
        return clusters.sorted { $0.weight > $1.weight }.map {
            PaletteColor(color: RGBAColor(red: $0.rgb.x, green: $0.rgb.y, blue: $0.rgb.z).quantized, share: $0.weight / total)
        }
    }

    /// Joins the closest pair while it is nearly the same color and more than the fewest colors remain.
    private static func mergeTwins(_ input: [(rgb: SIMD3<Double>, weight: Double)]) -> [(rgb: SIMD3<Double>, weight: Double)] {
        var clusters = input
        func color(_ rgb: SIMD3<Double>) -> RGBAColor { RGBAColor(red: rgb.x, green: rgb.y, blue: rgb.z) }
        while clusters.count > countRange.lowerBound {
            var pair: (Int, Int)?, best = mergeDistance
            for a in 0..<clusters.count {
                for b in (a + 1)..<clusters.count {
                    let d = color(clusters[a].rgb).distance(to: color(clusters[b].rgb))
                    if d < best { best = d; pair = (a, b) }
                }
            }
            guard let (a, b) = pair else { break }
            let weight = clusters[a].weight + clusters[b].weight
            clusters[a] = ((clusters[a].rgb * clusters[a].weight + clusters[b].rgb * clusters[b].weight) / weight, weight)
            clusters.remove(at: b)
        }
        return clusters
    }

    private static func squaredDistance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return d.x * d.x + d.y * d.y + d.z * d.z
    }

    /// The image as straight RGBA bytes in sRGB, scaled to fit `sampleSize`.
    private static func pixels(of image: CGImage) -> [UInt8]? {
        let scale = min(1, Double(sampleSize) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Undo the premultiplying so a half see-through red is still red.
        var i = 0
        while i < data.count {
            let a = Int(data[i + 3])
            if a > 0 && a < 255 {
                for c in 0..<3 { data[i + c] = UInt8(min(255, (Int(data[i + c]) * 255 + a / 2) / a)) }
            }
            i += 4
        }
        return data
    }
}
