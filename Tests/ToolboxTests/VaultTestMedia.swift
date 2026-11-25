import AVFoundation
import UniformTypeIdentifiers
import XCTest

enum VaultTestMedia {
    static func video(at url: URL, seconds: Int) async throws -> URL {
        let side = 256, fps: Int32 = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * Int(fps)) {
            try await waitUntilReady(input, of: writer)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<side {
                for x in 0..<side {
                    let i = y * rowBytes + x * 4
                    base[i] = 20
                    base[i + 1] = 20
                    base[i + 2] = 230
                    base[i + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    /// A small PNG with random pixels, so no two photos made here are copies of each other or look alike.
    static func uniquePhoto(at url: URL, red: UInt8 = 200) throws -> URL {
        let side = 8
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = red
            pixels[i + 1] = UInt8.random(in: 0...255)
            pixels[i + 2] = UInt8.random(in: 0...255)
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    enum Scene { case stripes, rings }

    static func sceneVideo(at url: URL, scene: Scene, seconds: Int, width: Int, height: Int, bitrate: Int,
                           codec: AVVideoCodecType = .h264) async throws -> URL {
        let fps: Int32 = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * Int(fps)) {
            try await waitUntilReady(input, of: writer)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            let time = Double(frame) / Double(fps)
            for y in 0..<height {
                for x in 0..<width {
                    let level = brightness(scene, x: Double(x) / Double(width), y: Double(y) / Double(height), time: time)
                    let i = y * rowBytes + x * 4
                    base[i] = level
                    base[i + 1] = level
                    base[i + 2] = level
                    base[i + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    static func sceneImage(_ scene: Scene, side: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<side {
            for x in 0..<side {
                pixels[y * side + x] = brightness(scene, x: Double(x) / Double(side), y: Double(y) / Double(side), time: 0)
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private static func brightness(_ scene: Scene, x: Double, y: Double, time: Double) -> UInt8 {
        let wave: Double
        switch scene {
        case .stripes: wave = sin((x * 3 + y * 2) * .pi * 2 + time * 1.3)
        case .rings: wave = cos(hypot(x - 0.3 - time * 0.05, y - 0.6) * .pi * 9)
        }
        return UInt8(max(0, min(255, 128 + wave * 110)))
    }
}
