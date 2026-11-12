import AVFoundation
import VideoToolbox

enum VideoCompressError: LocalizedError {
    case noVideo
    case cannotRead(String)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: "This file has no video that can be read."
        case .cannotRead(let why): "The video could not be read. \(why)"
        case .cannotWrite(let why): "The smaller video could not be saved. \(why)"
        }
    }
}

struct VideoCompressResult: Equatable {
    let url: URL
    let originalBytes: Int64
    let newBytes: Int64
    let size: CGSize

    var savedBytes: Int64 { max(originalBytes - newBytes, 0) }
    /// 0...1
    var savedFraction: Double { originalBytes > 0 ? Double(savedBytes) / Double(originalBytes) : 0 }
}

enum VideoCompressOutcome: Equatable {
    case compressed(VideoCompressResult)
    /// The new file was not smaller, so it was thrown away and the original is all there is.
    case notSmaller(originalBytes: Int64, newBytes: Int64)
}

/// Saves a smaller copy of a video. The original is never touched.
enum VideoCompressor {
    static func outputBase(for source: URL) -> String {
        source.deletingPathExtension().lastPathComponent + " (Compressed)"
    }

    static func compress(source: URL, settings: VideoCompressSettings, into folder: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> VideoCompressOutcome {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoCompressError.noVideo }
        let assetDuration = try await asset.load(.duration)
        let duration = assetDuration.seconds
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = Double(try await track.load(.nominalFrameRate))
        let dataRate = Double(try await track.load(.estimatedDataRate))
        let formats = try await track.load(.formatDescriptions)
        let metadata = (try? await asset.load(.metadata)) ?? []
        let audioTracks = settings.removeAudio ? [] : try await asset.loadTracks(withMediaType: .audio)
        var audioChannels = 2
        var audioRate = 48_000.0
        if let first = audioTracks.first, let any = try await first.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(any)?.pointee {
            audioChannels = Int(asbd.mChannelsPerFrame)
            audioRate = asbd.mSampleRate
        }
        let audioFormat = VideoCompressPlan.audioFormat(channels: audioChannels, sampleRate: audioRate, quality: settings.quality)

        let display = natural.applying(transform)
        let size = VideoCompressPlan.outputSize(source: CGSize(width: abs(display.width), height: abs(display.height)),
                                           maxShortSide: settings.maxSize.shortSide)
        // The picture is only re-rendered when it changes size; otherwise it is read as stored and turned by the file's own flag.
        let resized = size != CGSize(width: abs(display.width), height: abs(display.height))
        let bitrate = VideoCompressPlan.videoBitrate(size: size, frameRate: fps, settings: settings, sourceBitrate: dataRate)
        let originalBytes = fileSize(source)

        let output = BatchFiles.uniqueURL(in: folder, name: outputBase(for: source), ext: "mp4")
        var lastError: Error?
        // The first try uses the chosen encoder and keeps the file's details; the second is plain, in case the first is refused.
        for plain in [false, true] {
            do {
                let job = try Job(asset: asset, track: track, audioTracks: audioTracks, audioFormat: audioFormat,
                                  natural: natural, transform: transform, assetDuration: assetDuration,
                                  size: size, resized: resized, bitrate: bitrate, fps: fps, duration: duration,
                                  isHDR: formats.contains(where: isHDR), settings: settings,
                                  metadata: plain ? [] : metadata, useEncoderChoice: !plain, output: output)
                try await job.run(progress: progress)
                let newBytes = fileSize(output)
                if newBytes >= originalBytes {
                    discard(output)
                    return .notSmaller(originalBytes: originalBytes, newBytes: newBytes)
                }
                return .compressed(VideoCompressResult(url: output, originalBytes: originalBytes, newBytes: newBytes, size: size))
            } catch is CancellationError {
                discard(output)
                throw CancellationError()
            } catch let error as Job.StartFailure {
                discard(output)
                lastError = error.underlying
            } catch {
                discard(output)
                throw error
            }
        }
        throw lastError ?? VideoCompressError.cannotWrite("")
    }

    static func discard(_ output: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: output)
        let folder = output.deletingLastPathComponent()
        let scratchPrefix = output.lastPathComponent + ".sb-"
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(scratchPrefix) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// HLG and PQ video holds more brightness than a normal screen shows; it is turned into standard video so it looks right everywhere.
    private static func isHDR(_ description: CMFormatDescription) -> Bool {
        guard let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        else { return false }
        return transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
            || transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
    }

    /// One reader-to-writer pass over a file.
    private final class Job: @unchecked Sendable {
        /// The writer would not start; a plainer try may still work.
        struct StartFailure: Error { let underlying: Error }

        private struct Lane {
            let output: AVAssetReaderOutput
            let input: AVAssetWriterInput
        }

        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let video: Lane
        private let audio: Lane?
        private let duration: Double
        private let lock = NSLock()
        private var gates: [Gate] = []
        private var isCancelled = false
        private let settled = Gate()

        /// Lets a waiting pump be released from outside: a cancelled writer never asks for more samples, so it can't release itself.
        private final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?
            private var opened = false
            func hold(_ continuation: CheckedContinuation<Void, Never>) {
                lock.lock()
                if opened { lock.unlock(); continuation.resume() } else { self.continuation = continuation; lock.unlock() }
            }
            func open() {
                lock.lock()
                opened = true
                let waiting = continuation
                continuation = nil
                lock.unlock()
                waiting?.resume()
            }
        }

        private func cancel() {
            lock.lock()
            let first = !isCancelled
            isCancelled = true
            let waiting = gates
            lock.unlock()
            guard first else { return }
            reader.cancelReading()
            writer.cancelWriting()
            waiting.forEach { $0.open() }
            settled.open()
        }

        private func finishCancelling() async {
            cancel()
            await withCheckedContinuation { settled.hold($0) }
        }

        private func register(_ gate: Gate) {
            lock.lock()
            gates.append(gate)
            let cancelled = isCancelled
            lock.unlock()
            if cancelled { gate.open() }
        }

        init(asset: AVURLAsset, track: AVAssetTrack, audioTracks: [AVAssetTrack],
             audioFormat format: (channels: Int, sampleRate: Double, bitrate: Int),
             natural: CGSize, transform: CGAffineTransform, assetDuration: CMTime,
             size: CGSize, resized: Bool, bitrate: Int, fps: Double, duration: Double, isHDR: Bool,
             settings: VideoCompressSettings, metadata: [AVMetadataItem], useEncoderChoice: Bool, output: URL) throws {
            self.duration = duration
            reader = try AVAssetReader(asset: asset)

            var readSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            if isHDR {
                readSettings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ]
            }
            let videoOutput: AVAssetReaderOutput
            if resized {
                // Some files turn the picture without moving it back into view (no translation in the matrix); put its corner at the origin.
                let shown = CGRect(origin: .zero, size: natural).applying(transform)
                let upright = transform.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
                let sx = size.width / max(shown.width, 1), sy = size.height / max(shown.height, 1)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(upright.concatenating(CGAffineTransform(scaleX: sx, y: sy)), at: .zero)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: assetDuration)
                instruction.layerInstructions = [layer]
                let composition = AVMutableVideoComposition()
                composition.renderSize = size
                composition.frameDuration = CMTime(value: 1, timescale: fps > 1 ? CMTimeScale(fps.rounded()) : 30)
                composition.instructions = [instruction]
                let composed = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: readSettings)
                composed.videoComposition = composition
                videoOutput = composed
            } else {
                videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readSettings)
            }
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else { throw VideoCompressError.cannotRead("") }
            reader.add(videoOutput)

            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            writer.metadata = metadata

            // Re-rendered video is already turned upright; otherwise the frames stay as stored and the file's own rotation flag is kept.
            let encoded = resized ? size : CGSize(width: abs(natural.width), height: abs(natural.height))
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ]
            if fps > 1 { compression[AVVideoExpectedSourceFrameRateKey] = fps }
            if settings.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: Int(encoded.width),
                AVVideoHeightKey: Int(encoded.height),
                AVVideoCompressionPropertiesKey: compression,
            ]
            if useEncoderChoice {
                videoSettings[AVVideoEncoderSpecificationKey] =
                    [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: settings.hardwareEncoder]
            }
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            videoInput.transform = resized ? .identity : transform
            guard writer.canAdd(videoInput) else { throw VideoCompressError.cannotWrite("") }
            writer.add(videoInput)
            video = Lane(output: videoOutput, input: videoInput)

            if audioTracks.isEmpty {
                audio = nil
            } else {
                let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                audioOutput.alwaysCopiesSampleData = false
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channels,
                    AVEncoderBitRateKey: format.bitrate,
                ])
                audioInput.expectsMediaDataInRealTime = false
                if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                    reader.add(audioOutput)
                    writer.add(audioInput)
                    audio = Lane(output: audioOutput, input: audioInput)
                } else {
                    audio = nil
                }
            }
        }

        func run(progress: @escaping @Sendable (Double) -> Void) async throws {
            guard writer.startWriting() else { throw StartFailure(underlying: writer.error ?? VideoCompressError.cannotWrite("")) }
            guard reader.startReading() else {
                writer.cancelWriting()
                throw VideoCompressError.cannotRead(reader.error?.localizedDescription ?? "")
            }
            writer.startSession(atSourceTime: .zero)

            try await withTaskCancellationHandler {
                async let pictureDone: Void = pump(video, queue: DispatchQueue(label: "compress.video"), progress: progress)
                async let soundDone: Void = pumpSound()
                _ = await (pictureDone, soundDone)
            } onCancel: {
                cancel()
            }

            if Task.isCancelled || writer.status == .cancelled {
                await finishCancelling()
                throw CancellationError()
            }
            if reader.status == .failed {
                writer.cancelWriting()
                throw VideoCompressError.cannotRead(reader.error?.localizedDescription ?? "")
            }
            guard writer.status == .writing else { throw VideoCompressError.cannotWrite(writer.error?.localizedDescription ?? "") }
            await writer.finishWriting()
            guard writer.status == .completed else { throw VideoCompressError.cannotWrite(writer.error?.localizedDescription ?? "") }
            progress(1)
        }

        private func pumpSound() async {
            guard let audio else { return }
            await pump(audio, queue: DispatchQueue(label: "compress.audio"), progress: nil)
        }

        /// Moves samples from reader to writer until the reader runs dry or something stops.
        private func pump(_ lane: Lane, queue: DispatchQueue, progress: (@Sendable (Double) -> Void)?) async {
            var reported = 0.0
            let gate = Gate()
            register(gate)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                gate.hold(done)
                var finished = false
                lane.input.requestMediaDataWhenReady(on: queue) { [writer, duration] in
                    while lane.input.isReadyForMoreMediaData, !finished {
                        guard writer.status == .writing, let sample = lane.output.copyNextSampleBuffer(), lane.input.append(sample) else {
                            finished = true
                            if writer.status == .writing { lane.input.markAsFinished() }
                            gate.open()
                            return
                        }
                        if let progress, duration > 0 {
                            let p = min(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration, 1)
                            if p - reported >= 0.01 { reported = p; progress(p) }
                        }
                    }
                }
            }
        }
    }
}
