import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// What to record. Area rects are in points, relative to the display's top-left corner.
enum RecordingTarget {
    case display(SCDisplay)
    case window(SCWindow)
    case area(SCDisplay, CGRect)
}

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noMicrophone
    case noFrames
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Allow it for Toolbox in System Settings > Privacy & Security > Microphone."
        case .noMicrophone: "No microphone was found."
        case .noFrames: "Nothing was recorded. The recording was too short or the screen could not be captured."
        case .writerFailed(let why): "The recording could not be saved. \(why)"
        }
    }
}

/// Records with ScreenCaptureKit and writes H.264 + AAC with AVAssetWriter.
/// Video, system audio and microphone buffers all arrive on `queue`, so the state below needs no locks.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Called on an arbitrary queue when capture stops by itself, e.g. the display was unplugged.
    var onInterrupted: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "toolbox.record-screen", qos: .userInteractive)
    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var mixer = AudioMixer(usesSystem: false, usesMicrophone: false)
    private var highlighter: ClickHighlighter?
    private(set) var outputURL: URL?

    private var sessionStarted = false
    private var startTime = CMTime.invalid
    private var lastTime = CMTime.zero
    private var lastAudioEnd = CMTime.zero
    private var lastSystemAudio: CFTimeInterval = 0

    // MARK: Start

    /// `excludedWindowIDs` are Toolbox's own helper windows (floating controls), always kept out of the video.
    func start(target: RecordingTarget, options: RecordingOptions, output: URL,
               excludedWindowIDs: Set<CGWindowID>, captureRect: @escaping () -> CGRect?) async throws {
        if options.microphone { try await Self.requireMicrophone() }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter {
            excludedWindowIDs.contains($0.windowID)
                || (!options.includeToolboxWindows && $0.owningApplication?.processID == ownPID)
        }

        let filter: SCContentFilter
        let points: CGSize
        let sourceRect: CGRect?
        switch target {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            points = CGSize(width: display.width, height: display.height)
            sourceRect = nil
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            points = window.frame.size
            sourceRect = nil
        case .area(let display, let rect):
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            points = rect.size
            sourceRect = rect
        }
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
        let size = RecordingGeometry.outputSize(nativePixels: CGSize(width: points.width * scale, height: points.height * scale),
                                                resolution: options.resolution)

        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate.rawValue))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = options.showPointer
        config.queueDepth = 6
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = options.systemAudio
        config.sampleRate = Int(AudioMixer.sampleRate)
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        try configureWriter(output: output, size: size, options: options)
        mixer = AudioMixer(usesSystem: options.systemAudio, usesMicrophone: options.microphone)
        sessionStarted = false
        lastAudioEnd = .zero
        lastSystemAudio = 0

        if options.highlightClicks {
            highlighter = ClickHighlighter(captureRect: captureRect)
            highlighter?.start()
        }

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            if options.microphone { try startMicrophone() }
            self.stream = stream
            try await stream.startCapture()
        } catch {
            teardownCapture()
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        outputURL = output
    }

    private func configureWriter(output: URL, size: (width: Int, height: Int), options: RecordingOptions) throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: options.format.fileType)
        let fps = options.frameRate.rawValue
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingGeometry.bitrate(width: size.width, height: size.height, frameRate: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        if options.hasAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioMixer.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            audioInput = audio
        } else {
            audioInput = nil
        }
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "")
        }
        self.writer = writer
        videoInput = video
    }

    private static func requireMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw RecorderError.microphoneDenied
        default: throw RecorderError.microphoneDenied
        }
    }

    private func startMicrophone() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw RecorderError.noMicrophone }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioMixer.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard session.canAddInput(input), session.canAddOutput(output) else { throw RecorderError.noMicrophone }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        micSession = session
        session.startRunning()
    }

    // MARK: Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio:
            lastSystemAudio = CACurrentMediaTime()
            handleAudio(sampleBuffer, from: .system, at: sampleBuffer.presentationTimeStamp)
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        var time = sampleBuffer.presentationTimeStamp
        if let clock = micSession?.synchronizationClock {
            time = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
        }
        handleAudio(sampleBuffer, from: .microphone, at: time)
    }

    private func handleVideo(_ buffer: CMSampleBuffer) {
        guard let writer, writer.status == .writing, let videoInput else { return }
        // ScreenCaptureKit also sends status-only buffers (idle, blank); only complete frames carry pixels.
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer)
        else { return }

        let time = buffer.presentationTimeStamp
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            startTime = time
            sessionStarted = true
        }
        highlighter?.draw(into: pixels)
        // Dropping a frame beats stalling capture when the encoder is behind.
        guard videoInput.isReadyForMoreMediaData else { return }
        if videoInput.append(buffer) { lastTime = max(lastTime, time) }
    }

    private func handleAudio(_ buffer: CMSampleBuffer, from source: AudioMixer.Source, at time: CMTime) {
        guard sessionStarted, let writer, writer.status == .writing, let audioInput,
              var samples = AudioSamples.stereo48k(from: buffer) else { return }
        let systemIsLive = CACurrentMediaTime() - lastSystemAudio < 0.25
        samples = mixer.push(samples, from: source, systemIsLive: systemIsLive)
        guard !samples.isEmpty else { return }

        // Never go backwards: the two sources run on separate clocks.
        let start = max(time, lastAudioEnd)
        guard start >= startTime, audioInput.isReadyForMoreMediaData,
              let out = AudioSamples.makeBuffer(samples, at: start) else { return }
        if audioInput.append(out) {
            lastAudioEnd = CMTimeAdd(start, CMTime(value: CMTimeValue(samples.count / 2), timescale: CMTimeScale(AudioMixer.sampleRate)))
            lastTime = max(lastTime, lastAudioEnd)
        }
    }

    // MARK: Stop

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onInterrupted?(error)
    }

    /// Stops capture and finishes the file. Returns the saved file.
    func stop() async throws -> URL {
        teardownCapture()
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        // Wait for any buffer still being handled before the inputs are closed.
        let end: CMTime = await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.lastTime) } }

        guard let writer, let url = outputURL else { throw RecorderError.noFrames }
        defer { self.writer = nil; videoInput = nil; audioInput = nil; outputURL = nil }
        guard sessionStarted else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.noFrames
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "")
        }
        return url
    }

    private func teardownCapture() {
        highlighter?.stop()
        highlighter = nil
        micSession?.stopRunning()
        micSession = nil
    }
}
