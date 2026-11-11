import Foundation
@preconcurrency import AVFoundation
import Speech

public enum AppleSpeechStatus: Sendable {
    case checking, unavailable, unsupported, downloadRequired, downloading, installed
    public var title: String {
        switch self {
        case .checking: L("Checking availability…")
        case .unavailable: L("Apple SpeechTranscriber is unavailable on this Mac.")
        case .unsupported: L("This language is not supported by Apple SpeechTranscriber.")
        case .downloadRequired: L("Language model download required")
        case .downloading: L("Downloading…")
        case .installed: L("Ready for offline transcription")
        }
    }
}

public struct AppleSpeechUpdate: Sendable {
    public var finalized: [TranscriptSegment] = []
    public var partial: TranscriptSegment?
}

public actor NativeAppleSpeech {
    private var locale: Locale?
    private var liveAnalyzer: SpeechAnalyzer?
    private var liveInput: AsyncStream<AnalyzerInput>.Continuation?
    private var liveResults: Task<Void, Error>?
    private var liveConverter: AVAudioConverter?
    private var liveFailure: (any Error)?
    public init() {}

    public static func supportedLocales() async -> [String] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
    }

    public static func status(locale identifier: String) async -> AppleSpeechStatus {
        guard SpeechTranscriber.isAvailable else { return .unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else { return .unsupported }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .downloadRequired
        case .unsupported: return .unsupported
        @unknown default: return .unavailable
        }
    }

    public static func install(locale identifier: String) async throws {
        let locale = try await supportedLocale(identifier)
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        // This app uses one Apple language at a time. Release only this app's old reservations.
        for old in await AssetInventory.reservedLocales where old != locale {
            await AssetInventory.release(reservedLocale: old)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: { request.progress.cancel() }
        }
        try Task.checkCancellation()
    }

    public func load(locale identifier: String) async throws {
        try Task.checkCancellation()
        let locale = try await Self.supportedLocale(identifier)
        guard await Self.status(locale: identifier) == .installed else {
            throw AppError("Install the Apple language model in Settings first.")
        }
        self.locale = locale
    }

    public func transcribe(_ chunk: AudioChunk, vocabulary: String) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        guard let locale else { throw AppError("The local model is not loaded.") }
        guard !chunk.samples.isEmpty,
              chunk.samples.reduce(Float.zero, { $0 + $1 * $1 }) / Float(chunk.samples.count) >= 0.00000001 else { return [] }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])
        return try await withTaskCancellationHandler {
            do {
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                    throw AppError("Apple SpeechTranscriber could not select an audio format.")
                }
                let input = try Self.input(chunk.samples, format: format)
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                try await analyzer.setContext(context)
                async let results: [TranscriptSegment] = Self.collect(module, chunk: chunk)
                let sequence = AsyncStream<AnalyzerInput> { continuation in
                    continuation.yield(input)
                    continuation.finish()
                }
                if let last = try await analyzer.analyzeSequence(sequence) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else { await analyzer.cancelAndFinishNow() }
                let segments = try await results
                try Task.checkCancellation()
                return segments
            } catch {
                await analyzer.cancelAndFinishNow()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }

    /// One analyzer for the whole live session, with provisional text and natural final results.
    public func startLive(vocabulary: String, onUpdate: @escaping @Sendable (AppleSpeechUpdate) async throws -> Void,
                          onFailure: @escaping @Sendable () async -> Void = {}) async throws {
        guard let locale else { throw AppError("The local model is not loaded.") }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        liveAnalyzer = analyzer; liveFailure = nil
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              let source = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: source, to: format) else {
            throw AppError("Apple SpeechTranscriber could not select an audio format.")
        }
        liveConverter = converter
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(640))
        liveInput = pair.continuation
        liveResults = Task(priority: .userInitiated) {
            var id = UUID()
            do {
                for try await result in module.results {
                    try Task.checkCancellation()
                    var segment = TranscriptSegment(start: max(0, result.range.start.seconds),
                        end: max(0, result.range.end.seconds),
                        text: String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines))
                    segment.id = id
                    try await onUpdate(AppleSpeechUpdate(finalized: result.isFinal ? [segment] : [], partial: result.isFinal ? nil : segment))
                    if result.isFinal { id = UUID() }
                }
            } catch {
                liveFailure = error
                if !Task.isCancelled { await onFailure() }
                throw error
            }
        }
        try await analyzer.start(inputSequence: pair.stream)
    }

    public func acceptLive(_ chunk: AudioChunk) async throws {
        try Task.checkCancellation()
        if let liveFailure { throw liveFailure }
        guard let converter = liveConverter, liveAnalyzer != nil else { throw AppError("The local model is not loaded.") }
        guard !chunk.samples.isEmpty else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count))!
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        var supplied = false
        try convertLive { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
    }

    private func convertLive(_ input: AVAudioConverterInputBlock) throws {
        guard let converter = liveConverter,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4096) else { return }
        while true {
            var error: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            if let error { throw error }
            guard status != .error else { throw AppError("Audio conversion failed.") }
            if output.frameLength > 0 {
                // The analyzer owns each buffer after yielding; never reuse its backing storage.
                let copy = AVAudioPCMBuffer(pcmFormat: output.format, frameCapacity: output.frameLength)!
                copy.frameLength = output.frameLength
                let source = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for (src, dst) in zip(source, destination) {
                    if let s = src.mData, let d = dst.mData { memcpy(d, s, Int(src.mDataByteSize)) }
                }
                if case .dropped = liveInput?.yield(AnalyzerInput(buffer: copy)) {
                    throw AppError("Transcription could not keep up. Capture stopped and text was retained. Try a smaller model.")
                }
            }
            if status != .haveData || output.frameLength == 0 { break }
        }
    }

    public func finishLive() async throws {
        guard let analyzer = liveAnalyzer else { return }
        if let liveFailure { throw liveFailure }
        try convertLive { _, status in status.pointee = .endOfStream; return nil }
        liveInput?.finish()
        try await withTaskCancellationHandler {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await liveResults?.value
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
        liveAnalyzer = nil; liveInput = nil; liveResults = nil; liveConverter = nil
    }

    public func unload() async {
        liveResults?.cancel(); liveInput?.finish()
        await liveAnalyzer?.cancelAndFinishNow()
        _ = try? await liveResults?.value
        liveAnalyzer = nil; liveInput = nil; liveResults = nil; liveConverter = nil; liveFailure = nil
        locale = nil
    }

    private static func supportedLocale(_ identifier: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw AppError("Apple SpeechTranscriber is unavailable on this Mac.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw AppError("This language is not supported by Apple SpeechTranscriber.")
        }
        return locale
    }

    private static func collect(_ module: SpeechTranscriber, chunk: AudioChunk) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for try await result in module.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = min(chunk.duration, max(0, result.range.start.seconds))
            let end = min(chunk.duration, max(start, result.range.end.seconds))
            segments.append(TranscriptSegment(start: chunk.start + start, end: chunk.start + end, text: text))
        }
        return segments
    }

    private static func input(_ samples: [Float], format: AVAudioFormat) throws -> AnalyzerInput {
        let source = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * format.sampleRate / 16_000)) + 64) else {
            throw AppError("Apple SpeechTranscriber could not select an audio format.")
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true; inputStatus.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard status != .error else { throw AppError("Apple SpeechTranscriber could not select an audio format.") }
        return AnalyzerInput(buffer: output)
    }
}
