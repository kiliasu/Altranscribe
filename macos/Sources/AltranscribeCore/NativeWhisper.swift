import Foundation
import WhisperBridge

private final class WhisperHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { alt_whisper_free(pointer) }
    func cancel() { alt_whisper_cancel(pointer) }
}

private final class SegmentCollector {
    var segments: [TranscriptSegment] = []
}

public actor NativeWhisper {
    private var handle: WhisperHandle?
    public init() {}

    public func load(model: String, useGPU: Bool) throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: model), !model.isEmpty else {
            throw AppError("Download or select a Whisper model in Settings first.")
        }
        guard let pointer = alt_whisper_create(model, useGPU) else {
            throw AppError("Could not load the Whisper model. Check the file, or try disabling Metal.")
        }
        handle = WhisperHandle(pointer)
        try Task.checkCancellation()
    }

    public func transcribe(_ chunk: AudioChunk, language: String, vocabulary: String) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        guard let handle else { throw AppError("The local model is not loaded.") }
        guard !chunk.samples.isEmpty else { return [] }
        // Avoid generating text for digital silence without filtering actual words.
        let energy = chunk.samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(chunk.samples.count)
        if energy < 0.00000001 { return [] }
        let collector = SegmentCollector()
        alt_whisper_reset_cancel(handle.pointer)
        let result = await withTaskCancellationHandler {
            chunk.samples.withUnsafeBufferPointer { samples in
                alt_whisper_transcribe(handle.pointer, samples.baseAddress, Int32(samples.count), language, vocabulary,
                    { start, end, rawText, user in
                        guard let user, let rawText else { return }
                        let collector = Unmanaged<SegmentCollector>.fromOpaque(user).takeUnretainedValue()
                        let text = String(cString: rawText).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            collector.segments.append(TranscriptSegment(start: Double(start) / 1000, end: Double(end) / 1000, text: text))
                        }
                    }, Unmanaged.passUnretained(collector).toOpaque())
            }
        } onCancel: { handle.cancel() }
        try Task.checkCancellation()
        guard result == 0 else { throw AppError("Local transcription failed. Earlier text was retained.") }
        return collector.segments.map {
            var segment = $0
            segment.start = chunk.start + min(chunk.duration, max(0, segment.start))
            segment.end = chunk.start + min(chunk.duration, max(0, segment.end))
            return segment
        }
    }

    public func unload() { handle = nil }
}

public struct AudioChunker: Sendable {
    private var pending: [Float] = []
    private var sampleOffset = 0
    public let chunkSamples: Int
    public init(seconds: Double) { chunkSamples = max(1, Int(seconds * 16_000)) }
    public mutating func append(_ samples: [Float]) -> [AudioChunk] {
        pending.append(contentsOf: samples)
        var chunks: [AudioChunk] = []
        while pending.count >= chunkSamples {
            chunks.append(AudioChunk(samples: Array(pending.prefix(chunkSamples)), start: Double(sampleOffset) / 16_000))
            pending.removeFirst(chunkSamples)
            sampleOffset += chunkSamples
        }
        return chunks
    }
    public mutating func flush() -> AudioChunk? {
        guard !pending.isEmpty else { return nil }
        let chunk = AudioChunk(samples: pending, start: Double(sampleOffset) / 16_000)
        sampleOffset += pending.count
        pending.removeAll(keepingCapacity: true)
        return chunk
    }
    public var duration: Double { Double(sampleOffset + pending.count) / 16_000 }
}
