import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor VaultThumbnails {
    static let maxPixels = 480
    private static let jpegQuality = 0.8
    private static let videoFrameSecond = 1.0

    let folder: URL
    private let vaultRoot: URL
    private let requiresMountedVolume: Bool
    private var memory: [String: CGImage] = [:]

    init(vaultRoot: URL, requiresMountedVolume: Bool = true) {
        self.vaultRoot = vaultRoot
        self.requiresMountedVolume = requiresMountedVolume
        folder = vaultRoot.appendingPathComponent(VaultLibrary.privateFolderName).appendingPathComponent("thumbs")
    }

    private var vaultIsMounted: Bool {
        !requiresMountedVolume || (try? vaultRoot.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    func image(for item: VaultItem) async -> CGImage? {
        let key = Self.key(for: item)
        if let cached = memory[key] { return cached }
        let file = folder.appendingPathComponent(key + ".jpg")
        if let stored = Self.load(file) {
            memory[key] = stored
            return stored
        }
        guard vaultIsMounted, let made = await Self.make(for: item), vaultIsMounted else { return nil }
        memory[key] = made
        Self.save(made, to: file, inside: folder.deletingLastPathComponent())
        return made
    }

    func remove(_ item: VaultItem) {
        let key = Self.key(for: item)
        memory[key] = nil
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(key + ".jpg"))
    }

    func forget() { memory.removeAll() }

    static func key(for item: VaultItem) -> String {
        let digest = SHA256.hash(data: Data("\(item.id)|\(item.bytes)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func make(for item: VaultItem) async -> CGImage? {
        switch item.kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        case .video:
            let asset = AVURLAsset(url: item.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let second = duration.isFinite ? min(videoFrameSecond, duration / 2) : 0
            return try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image
        }
    }

    private static func load(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func save(_ image: CGImage, to file: URL, inside privateFolder: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: privateFolder, withIntermediateDirectories: false)
        try? fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: false)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
