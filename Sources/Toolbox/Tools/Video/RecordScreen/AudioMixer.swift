import CoreMedia

/// Mixes system audio and the microphone into one stereo Float32 stream (48 kHz, interleaved),
/// so players that only play the first audio track still hear both.
///
/// System audio is the clock while it is flowing: each system chunk is output together with the same
/// amount of microphone audio. When system audio goes quiet (macOS may stop delivering silent buffers),
/// microphone audio passes straight through so the voice is never held back.
struct AudioMixer {
    enum Source { case system, microphone }

    static let sampleRate = 48_000.0
    /// Most microphone audio held back waiting for a system chunk, in samples (0.5 s of stereo).
    private static let maxPending = 48_000

    let usesSystem: Bool
    let usesMicrophone: Bool
    private var pendingMic: [Float] = []

    init(usesSystem: Bool, usesMicrophone: Bool) {
        self.usesSystem = usesSystem
        self.usesMicrophone = usesMicrophone
    }

    /// Returns the interleaved stereo samples that are ready to be written, possibly none.
    /// `systemIsLive` says whether system audio arrived recently.
    mutating func push(_ samples: [Float], from source: Source, systemIsLive: Bool = true) -> [Float] {
        guard usesSystem && usesMicrophone else { return samples }
        switch source {
        case .system:
            let take = min(samples.count, pendingMic.count)
            var out = samples
            for i in 0..<take { out[i] = Self.clamp(samples[i] + pendingMic[i]) }
            pendingMic.removeFirst(take)
            return out
        case .microphone:
            if !systemIsLive {
                let out = pendingMic + samples
                pendingMic.removeAll(keepingCapacity: true)
                return out
            }
            pendingMic.append(contentsOf: samples)
            if pendingMic.count > Self.maxPending { pendingMic.removeFirst(pendingMic.count - Self.maxPending) }
            return []
        }
    }

    private static func clamp(_ v: Float) -> Float { min(1, max(-1, v)) }
}

enum AudioSamples {
    /// Interleaved stereo Float32 at 48 kHz from a PCM sample buffer, or nil when the format is not 32-bit float PCM.
    static func stereo48k(from buffer: CMSampleBuffer) -> [Float]? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32,
              asbd.mChannelsPerFrame > 0
        else { return nil }
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0 else { return nil }

        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr
        else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr
        else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        func sample(_ channel: Int, _ frame: Int) -> Float {
            let c = min(channel, channels - 1)
            if interleaved {
                guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return 0 }
                return data[frame * channels + c]
            }
            guard c < buffers.count, let data = buffers[c].mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            return data[frame]
        }
        var out = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            out[f * 2] = sample(0, f)
            out[f * 2 + 1] = sample(1, f)
        }
        return asbd.mSampleRate == AudioMixer.sampleRate ? out : resample(out, from: asbd.mSampleRate)
    }

    /// Linear interpolation. Only a fallback: the capture sources are asked for 48 kHz already.
    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        let inFrames = samples.count / 2
        guard rate > 0, inFrames > 1 else { return samples }
        let outFrames = Int(Double(inFrames) * AudioMixer.sampleRate / rate)
        var out = [Float](repeating: 0, count: outFrames * 2)
        for f in 0..<outFrames {
            let pos = Double(f) * rate / AudioMixer.sampleRate
            let i = min(Int(pos), inFrames - 2)
            let t = Float(pos - Double(i))
            for c in 0..<2 { out[f * 2 + c] = samples[i * 2 + c] * (1 - t) + samples[(i + 1) * 2 + c] * t }
        }
        return out
    }

    /// Wraps interleaved stereo Float32 48 kHz samples in a sample buffer the AAC writer input accepts.
    static func makeBuffer(_ samples: [Float], at time: CMTime) -> CMSampleBuffer? {
        let frames = samples.count / 2
        guard frames > 0 else { return nil }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: AudioMixer.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr, let format else { return nil }
        let length = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &out) == noErr
        else { return nil }
        return out
    }
}
