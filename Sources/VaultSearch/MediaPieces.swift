@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct MediaPiece: Sendable, Equatable {
    public let file: URL
    public let start: Double
    public var end: Double
}

public enum MediaPieces {
    public static let photoMaxPixel = 1024
    public static let frameMaxPixel = 1024
    public static let frameInterval = 3.0
    public static let maxFrames = 1200
    public static let audioWindow = 30.0
    public static let audioHop = 25.0
    private static let sampleRate = 16_000.0
    private static let silence = 0.003
    private static let minimumAudioSeconds = 2.0
    private static let sameShotBits = 4
    private static let jpegQuality = 0.9

    public static func preparePhoto(_ url: URL, to folder: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw EmbedderError.failed("Not an image.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: photoMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw EmbedderError.failed("Can't decode the image.")
        }
        let out = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        try writeJPEG(thumbnail, to: out)
        return out
    }

    public static func videoFrames(of url: URL, to folder: URL) async throws -> [MediaPiece] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { return [] }
        let step = max(frameInterval, duration / Double(maxFrames))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameMaxPixel, height: frameMaxPixel)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = stride(from: min(0.5, duration / 2), to: duration, by: step).map { CMTime(seconds: $0, preferredTimescale: 600) }

        var frames: [MediaPiece] = []
        var lastHash: UInt64?
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            guard case let .success(_, image, actualTime) = result else { continue }
            let hash = averageHash(image)
            if let lastHash, (hash ^ lastHash).nonzeroBitCount <= sameShotBits { continue }
            lastHash = hash
            let out = folder.appendingPathComponent(UUID().uuidString + ".jpg")
            try writeJPEG(image, to: out)
            frames.append(MediaPiece(file: out, start: max(0, actualTime.seconds), end: duration))
        }
        guard !frames.isEmpty || times.isEmpty else { throw EmbedderError.failed("No frame of the video could be read.") }
        for index in frames.indices.dropLast() { frames[index].end = frames[index + 1].start }
        return frames
    }

    public static func soundtrack(of url: URL, to folder: URL) async throws -> [MediaPiece] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EmbedderError.failed("Can't read the sound.") }

        let windowSamples = Int(audioWindow * sampleRate), hopSamples = Int(audioHop * sampleRate)
        var buffer: [Int16] = []
        var offset = 0
        var pieces: [MediaPiece] = []
        func emit(_ count: Int) throws {
            let slice = buffer[0..<count]
            guard rms(slice) > silence else { return }
            let out = folder.appendingPathComponent(UUID().uuidString + ".wav")
            try writeWAV(slice, to: out)
            pieces.append(MediaPiece(file: out, start: Double(offset) / sampleRate, end: Double(offset + count) / sampleRate))
        }
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            _ = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            buffer.append(contentsOf: chunk)
            while buffer.count >= windowSamples {
                try emit(windowSamples)
                buffer.removeFirst(hopSamples)
                offset += hopSamples
            }
        }
        if reader.status == .failed { throw reader.error ?? EmbedderError.failed("Decoding the sound failed.") }
        let alreadyCovered = offset == 0 ? 0 : windowSamples - hopSamples
        if buffer.count - alreadyCovered >= Int(minimumAudioSeconds * sampleRate) { try emit(buffer.count) }
        return pieces
    }

    public static func averageHash(_ image: CGImage) -> UInt64 {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 0 }
        let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var hash: UInt64 = 0
        for (index, pixel) in pixels.enumerated() where Int(pixel) > mean { hash |= 1 << UInt64(index) }
        return hash
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EmbedderError.failed("Can't write a frame.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EmbedderError.failed("Can't encode a frame.") }
    }

    private static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32768
            sum += value * value
        }
        return (sum / Double(samples.count)).squareRoot()
    }

    private static func writeWAV(_ samples: ArraySlice<Int16>, to url: URL) throws {
        var data = Data(capacity: 44 + samples.count * 2)
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        append("RIFF"); append32(UInt32(36 + samples.count * 2)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1); append32(rate); append32(rate * 2); append16(2); append16(16)
        append("data"); append32(UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }
}
