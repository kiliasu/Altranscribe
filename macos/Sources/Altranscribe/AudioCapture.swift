@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AudioToolbox
import AltranscribeCore

/// Audio callbacks and the chunk buffer are confined to this serial queue.
final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.altranscribe.capture", qos: .userInitiated, autoreleaseFrequency: .workItem)
    let stream: AsyncThrowingStream<AudioChunk, Error>
    private let continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    private var chunker: LiveAudioChunker
    private var gain = AdaptiveInputGain()
    private let adaptiveGain: Bool
    private var paused = false
    private var finished = false
    private var converter: AVAudioConverter?
    private let recordingURL: URL?
    private var recording: AVAudioFile?
    private var recordingFrames: AVAudioFramePosition = 0
    private var recordedDuration: Double?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let meter: @Sendable (Float, Double) -> Void

    init(chunkSeconds: Double = 8, automaticChunks: Bool = false, adaptiveGain: Bool = false, recordingURL: URL? = nil, meter: @escaping @Sendable (Float, Double) -> Void) {
        chunker = LiveAudioChunker(seconds: chunkSeconds, automatic: automaticChunks)
        self.adaptiveGain = adaptiveGain
        self.recordingURL = recordingURL
        // Keep the same 64-second audio budget for both streaming and batch engines.
        let capacity = max(1, Int(64 / chunkSeconds))
        let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        stream = pair.stream; continuation = pair.continuation; self.meter = meter
    }

    func microphone(_ input: AVAudioPCMBuffer) {
        // AVAudioEngine reuses its tap buffer after the callback; copy before queueing it.
        guard let copy = Self.copy(input, offset: 0, count: input.frameLength) else { return }
        queue.async { self.consume(copy) }
    }

    private static func copy(_ input: AVAudioPCMBuffer, offset: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count) else { return nil }
        copy.frameLength = count
        let stride = Int(input.format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, target) in zip(source, target) {
            if let src = source.mData, let dst = target.mData { memcpy(dst, src.advanced(by: Int(offset) * stride), Int(count) * stride) }
        }
        return copy
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        guard !paused, !finished else { return }
        if let recordingURL {
            do {
                if recording == nil {
                    try FileManager.default.createDirectory(at: recordingURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    recording = try AVAudioFile(forWriting: recordingURL,
                        settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: input.format.sampleRate,
                                   AVNumberOfChannelsKey: input.format.channelCount,
                                   AVEncoderBitRateKey: (input.format.sampleRate < 24_000 ? 32_000 : 64_000) * Int(input.format.channelCount)],
                        commonFormat: input.format.commonFormat, interleaved: input.format.isInterleaved)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordingURL.path)
                }
                try recording?.write(from: input)
                recordingFrames += AVAudioFramePosition(input.frameLength)
            } catch {
                fail(AppError("Could not save the recording. Capture stopped; the transcript and any recorded audio were retained.")); return
            }
        }
        if converter?.inputFormat != input.format { converter = AVAudioConverter(from: input.format, to: target) }
        guard let converter else { fail(AppError("Could not convert the input audio format.")); return }
        var offset: AVAudioFrameCount = 0
        convert(converter) { requested, status in
            guard offset < input.frameLength else { status.pointee = .noDataNow; return nil }
            let count = min(requested, input.frameLength - offset)
            let part = Self.copy(input, offset: offset, count: count)
            offset += count
            status.pointee = .haveData
            return part
        }
    }

    private func convert(_ converter: AVAudioConverter, input: AVAudioConverterInputBlock) {
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { return }
        while !finished {
            var error: NSError?
            output.frameLength = 0
            let result = converter.convert(to: output, error: &error, withInputFrom: input)
            guard result != .error, error == nil else {
                fail(AppError("Audio conversion failed.")); return
            }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                accept(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
            }
            if result != .haveData || output.frameLength == 0 { break }
        }
    }

    private func flushConverter() {
        guard let converter else { return }
        convert(converter) { _, status in status.pointee = .endOfStream; return nil }
        converter.reset()
    }

    private func accept(_ samples: [Float]) {
        if samples.isEmpty { return }
        let samples = adaptiveGain ? gain.process(samples) : samples
        let rms = sqrt(samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count))
        for chunk in chunker.append(samples) { emit(chunk) }
        meter(min(1, rms * 8), chunker.duration)
    }

    private func emit(_ chunk: AudioChunk) {
        if case .dropped = continuation.yield(chunk) {
            fail(AppError("Transcription could not keep up. Capture stopped and text was retained. Try a smaller model."))
        }
    }
    private func closeRecording() {
        if let recording {
            recordedDuration = Double(recordingFrames) / recording.processingFormat.sampleRate
            recording.close()
            self.recording = nil
        }
    }
    private func fail(_ error: Error) { closeRecording(); finished = true; continuation.finish(throwing: error) }
    func microphoneChanged() {
        queue.async { self.fail(AppError("The microphone changed or disconnected. Select a microphone and start a new recording.")) }
    }
    func setPaused(_ value: Bool) {
        queue.async {
            if value {
                self.flushConverter()
                if let tail = self.chunker.flush() { self.emit(tail) }
            }
            self.paused = value
        }
    }
    @discardableResult func finish() async -> Double? {
        await withCheckedContinuation { done in
            queue.async {
                if !self.finished {
                    self.flushConverter()
                    if let tail = self.chunker.flush() { self.emit(tail) }
                    self.closeRecording()
                    self.finished = true
                    self.continuation.finish()
                }
                done.resume(returning: self.recordedDuration)
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail(AppError("System audio capture stopped. Check Screen Recording permission.")) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        do {
            try sampleBuffer.withAudioBufferList { buffers, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { return }
                pcm.frameLength = pcm.frameCapacity
                let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                for (source, target) in zip(buffers, destination) {
                    if let src = source.mData, let dst = target.mData { memcpy(dst, src, min(Int(source.mDataByteSize), Int(target.mDataByteSize))) }
                }
                consume(pcm)
            }
        } catch { fail(AppError("Could not read system audio.")) }
    }
}

@MainActor final class AudioCapture {
    private var engine: AVAudioEngine?
    private var screenStream: SCStream?
    private var sink: CaptureSink?
    private var microphoneObserver: NSObjectProtocol?
    private var stopping: Task<Double?, Never>?
    private(set) var recordedDuration: Double?

    func start(source: AudioSource, chunkSeconds: Double = 8, automaticChunks: Bool = false, adaptiveGain: Bool = false, voiceProcessing: Bool = false, microphoneUID: String? = nil, recordingURL: URL? = nil, meter: @escaping @Sendable (Float, Double) -> Void) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        recordedDuration = nil
        let sink = CaptureSink(chunkSeconds: chunkSeconds, automaticChunks: automaticChunks, adaptiveGain: adaptiveGain && !(source == .microphone && voiceProcessing), recordingURL: recordingURL, meter: meter)
        self.sink = sink
        do {
            if source == .microphone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw AppError("Allow Altranscribe in System Settings → Privacy & Security → Microphone.")
                }
                try Task.checkCancellation()
                let device = try MicrophoneDevice.resolve(microphoneUID)
                let engine = AVAudioEngine()
                let input = engine.inputNode
                if voiceProcessing {
                    do {
                        try input.setVoiceProcessingEnabled(true)
                        input.isVoiceProcessingAGCEnabled = adaptiveGain
                        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                    } catch {
                        throw AppError("Apple voice processing is unavailable for this input. Turn it off or select another microphone.")
                    }
                }
                if microphoneUID != nil { try Self.select(device, on: input) }
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw AppError("No microphone is available.")
                }
                // The tap runs on AVAudioEngine's audio queue, not this MainActor.
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in sink.microphone(buffer) }
                self.engine = engine
                engine.prepare()
                try engine.start()
                microphoneObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                    object: engine, queue: nil) { [weak self, weak engine] _ in
                        Task { @MainActor [weak self, weak engine] in
                            guard let self, let engine, self.engine === engine else { return }
                            self.resumeMicrophone(engine, device: device, format: format, sink: sink)
                        }
                    }
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard let display = content.displays.first else { throw AppError("No display is available for system audio capture.") }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 1
                config.width = 2; config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.queueDepth = 3
                let stream = SCStream(filter: filter, configuration: config, delegate: sink)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                screenStream = stream
                try await stream.startCapture()
            }
            return sink.stream
        } catch {
            await stop()
            if let captureError = error as? SCStreamError, captureError.code == .userDeclined {
                throw AppError("Allow Altranscribe in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app.")
            }
            throw error
        }
    }
    func pause(_ value: Bool) { sink?.setPaused(value) }
    /// Select this engine's input, without changing the system default used by other apps.
    static func select(_ device: MicrophoneDevice, on input: AVAudioInputNode) throws {
        var id = device.audioID
        guard let unit = input.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &id, UInt32(MemoryLayout.size(ofValue: id))) == noErr else {
            throw AppError("Could not use the selected microphone. Choose another microphone or turn off Apple voice processing.")
        }
    }
    private func resumeMicrophone(_ engine: AVAudioEngine, device: MicrophoneDevice, format: AVAudioFormat, sink: CaptureSink) {
        // Selecting an input can deliver a configuration notification after start(). Only resume
        // the same device and tap format; a real route change must never capture another input.
        var actual = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard MicrophoneDevice.available().contains(where: { $0.id == device.id && $0.audioID == device.audioID }),
              let unit = engine.inputNode.audioUnit,
              AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr,
              actual == device.audioID, engine.inputNode.outputFormat(forBus: 0) == format else {
            sink.microphoneChanged(); return
        }
        do { if !engine.isRunning { try engine.start() } }
        catch { sink.microphoneChanged() }
    }
    func stop() async {
        if let stopping { recordedDuration = await stopping.value; return }
        if let microphoneObserver { NotificationCenter.default.removeObserver(microphoneObserver); self.microphoneObserver = nil }
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop(); self.engine = nil }
        let screen = screenStream
        let currentSink = sink
        screenStream = nil; sink = nil
        guard currentSink != nil || screen != nil else { return }
        let task = Task {
            if let screen { try? await screen.stopCapture() }
            return await currentSink?.finish()
        }
        stopping = task
        recordedDuration = await task.value
        stopping = nil
    }
}
