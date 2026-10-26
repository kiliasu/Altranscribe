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

public actor NativeAppleSpeech {
    private var locale: Locale?
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

    public func unload() { locale = nil }

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
