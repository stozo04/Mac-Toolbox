import AVFoundation
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
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
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

    enum Scene { case stripes, rings }

    static func sceneVideo(at url: URL, scene: Scene, seconds: Int, side: Int, bitrate: Int) async throws -> URL {
        let fps: Int32 = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            let time = Double(frame) / Double(fps)
            for y in 0..<side {
                for x in 0..<side {
                    let level = brightness(scene, x: Double(x) / Double(side), y: Double(y) / Double(side), time: time)
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
