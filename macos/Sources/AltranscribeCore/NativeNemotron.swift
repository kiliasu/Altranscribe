import Foundation
import SherpaOnnxC

private final class NemotronHandle: @unchecked Sendable {
    let recognizer: OpaquePointer
    var stream: OpaquePointer?
    init(_ recognizer: OpaquePointer) { self.recognizer = recognizer }
    func closeStream() {
        if let stream { SherpaOnnxDestroyOnlineStream(stream); self.stream = nil }
    }
    deinit { closeStream(); SherpaOnnxDestroyOnlineRecognizer(recognizer) }
}

public struct NemotronUpdate: Sendable {
    public var finalized: [TranscriptSegment] = []
    public var partial: TranscriptSegment?
}

/// One serial recognizer; its stream retains encoder context between audio chunks.
public actor NativeNemotron {
    private var handle: NemotronHandle?
    private var language = "en"
    private var multilingual = false
    private var origin: Double = 0
    private var audioEnd: Double = 0
    private var tokens: [String] = []
    private var times: [Double] = []
    private var committed = 0
    private var segmentID = UUID()
    private var previous: TranscriptSegment?
    public init() {}

    public func load(model: NemotronModel, directory: URL, language: String) throws {
        try Task.checkCancellation()
        guard model.isComplete(at: directory) else {
            throw AppError("Download the selected Nemotron model in Settings first.")
        }
        handle = nil
        let strings = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
            .map { directory.appendingPathComponent($0).path } + ["cpu", "greedy_search"]
        let pointers = strings.map { strdup($0)! }
        defer { pointers.forEach { free($0) } }
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = UnsafePointer(pointers[0])
        config.model_config.transducer.decoder = UnsafePointer(pointers[1])
        config.model_config.transducer.joiner = UnsafePointer(pointers[2])
        config.model_config.tokens = UnsafePointer(pointers[3])
        config.model_config.provider = UnsafePointer(pointers[4])
        config.model_config.num_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
        config.decoding_method = UnsafePointer(pointers[5])
        // Segment by token timestamps; resetting at each audio chunk loses words and context.
        config.enable_endpoint = 0
        guard let recognizer = SherpaOnnxCreateOnlineRecognizer(&config) else {
            throw AppError("Could not load Nemotron. Download the model again and retry.")
        }
        handle = NemotronHandle(recognizer)
        multilingual = model.multilingual
        self.language = model.multilingual ? language : "en"
        try Task.checkCancellation()
    }

    public func beginStream() {
        handle?.closeStream()
        tokens = []; times = []; committed = 0; previous = nil
        segmentID = UUID(); origin = 0; audioEnd = 0
    }

    public func accept(_ chunk: AudioChunk) throws -> NemotronUpdate {
        try Task.checkCancellation()
        guard let handle else { throw AppError("Nemotron is not loaded.") }
        var update = NemotronUpdate()
        // A media edit can jump forward in time. Close the old stream without fabricating a long silence.
        if handle.stream != nil, abs(chunk.start - audioEnd) > 0.02 {
            update.finalized = try finish().finalized
        }
        if handle.stream == nil {
            beginStream()
            guard let stream = SherpaOnnxCreateOnlineStream(handle.recognizer) else {
                throw AppError("Could not create a Nemotron audio stream.")
            }
            handle.stream = stream; origin = chunk.start; audioEnd = chunk.start
            if multilingual { SherpaOnnxOnlineStreamSetOption(stream, "language", language) }
        }
        guard let stream = handle.stream else { return update }
        // Small blocks keep cancellation responsive even when a file decoder delivers 20 seconds.
        for start in stride(from: 0, to: chunk.samples.count, by: 5120) {
            try Task.checkCancellation()
            let count = min(5120, chunk.samples.count - start)
            chunk.samples.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress!.advanced(by: start), Int32(count))
            }
            audioEnd = chunk.start + Double(start + count) / 16_000
            try decode(handle, stream: stream)
            update.finalized += segment(closing: false)
        }
        update.partial = partial()
        return update
    }

    public func finish() throws -> NemotronUpdate {
        guard let handle, let stream = handle.stream else { return NemotronUpdate() }
        defer { handle.closeStream() }
        try Task.checkCancellation()
        // Flush the model's look-ahead so Stop and EOF retain the last spoken words.
        let tail = [Float](repeating: 0, count: 16_000)
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, tail, Int32(tail.count))
        SherpaOnnxOnlineStreamInputFinished(stream)
        try decode(handle, stream: stream)
        return NemotronUpdate(finalized: segment(closing: true))
    }

    private func decode(_ handle: NemotronHandle, stream: OpaquePointer) throws {
        var decoded = false
        while SherpaOnnxIsOnlineStreamReady(handle.recognizer, stream) != 0 {
            try Task.checkCancellation()
            SherpaOnnxDecodeOnlineStream(handle.recognizer, stream)
            decoded = true
        }
        guard decoded, let result = SherpaOnnxGetOnlineStreamResult(handle.recognizer, stream) else { return }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        let value = result.pointee
        guard value.count > 0, let rawTokens = value.tokens_arr, let timestamps = value.timestamps else { return }
        tokens = (0..<Int(value.count)).map { rawTokens[$0].map { String(cString: $0) } ?? "" }
        times = (0..<Int(value.count)).map { Double(timestamps[$0]) }
    }

    private func piece(_ range: Range<Int>) -> TranscriptSegment? {
        guard !range.isEmpty else { return nil }
        let text = tokens[range].joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var result = TranscriptSegment(start: min(audioEnd, origin + times[range.lowerBound]),
            end: min(audioEnd, origin + times[range.upperBound - 1] + 0.3), text: text)
        result.id = segmentID
        return result
    }
    private func partial() -> TranscriptSegment? { piece(committed..<tokens.count) }

    private func segment(closing: Bool) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        // Nemotron can emit punctuation after the pause that completed the preceding line.
        let punctuation = CharacterSet(charactersIn: ".,!?;:。，！？；：、…")
        while committed < tokens.count, var last = previous {
            let text = tokens[committed].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.unicodeScalars.allSatisfy({ punctuation.contains($0) }) else { break }
            last.text += text; previous = last; committed += 1
            result.append(last)
        }
        while committed < tokens.count {
            let first = times[committed], last = times[tokens.count - 1]
            let gap = audioEnd - origin - last
            let pause = tokens.count - committed < 8 ? 2.6 : 1.5
            var cut = tokens.count
            if !closing, gap < pause {
                guard last - first >= 15 else { break }
                var widest = 0.0
                for i in (committed + 1)..<tokens.count where times[i] - first >= 8 {
                    if times[i] - times[i - 1] >= widest { widest = times[i] - times[i - 1]; cut = i }
                }
            }
            if let line = piece(committed..<cut) { result.append(line); previous = line }
            committed = cut; segmentID = UUID()
        }
        return result
    }

    public func unload() { beginStream(); handle = nil }
}
