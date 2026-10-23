@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AltranscribeCore

/// Audio callbacks and the chunk buffer are confined to this serial queue.
final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.altranscribe.capture", qos: .userInitiated)
    let stream: AsyncThrowingStream<AudioChunk, Error>
    private let continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    private var chunker: AudioChunker
    private var paused = false
    private var finished = false
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let meter: @Sendable (Float, Double) -> Void

    init(chunkSeconds: Double = 8, meter: @escaping @Sendable (Float, Double) -> Void) {
        chunker = AudioChunker(seconds: chunkSeconds)
        // Keep the same 64-second audio budget for both streaming and batch engines.
        let capacity = max(1, Int(ceil(64 / chunkSeconds)))
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
        let rms = sqrt(samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count))
        for chunk in chunker.append(samples) { emit(chunk) }
        meter(min(1, rms * 8), chunker.duration)
    }

    private func emit(_ chunk: AudioChunk) {
        if case .dropped = continuation.yield(chunk) {
            fail(AppError("Transcription could not keep up. Capture stopped and text was retained. Try a smaller model."))
        }
    }
    private func fail(_ error: Error) { finished = true; continuation.finish(throwing: error) }
    func setPaused(_ value: Bool) {
        queue.async {
            if value {
                self.flushConverter()
                if let tail = self.chunker.flush() { self.emit(tail) }
            }
            self.paused = value
        }
    }
    func finish() async {
        await withCheckedContinuation { done in
            queue.async {
                if !self.finished {
                    self.flushConverter()
                    if let tail = self.chunker.flush() { self.emit(tail) }
                    self.finished = true
                    self.continuation.finish()
                }
                done.resume()
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

    func start(source: AudioSource, chunkSeconds: Double = 8, meter: @escaping @Sendable (Float, Double) -> Void) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let sink = CaptureSink(chunkSeconds: chunkSeconds, meter: meter)
        self.sink = sink
        do {
            if source == .microphone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw AppError("Allow Altranscribe in System Settings → Privacy & Security → Microphone.")
                }
                try Task.checkCancellation()
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw AppError("No microphone is available.")
                }
                // The tap runs on AVAudioEngine's audio queue, not this MainActor.
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in sink.microphone(buffer) }
                self.engine = engine
                engine.prepare()
                try engine.start()
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
    func stop() async {
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop(); self.engine = nil }
        let screen = screenStream
        let currentSink = sink
        screenStream = nil; sink = nil
        if let screen { try? await screen.stopCapture() }
        await currentSink?.finish()
    }
}
