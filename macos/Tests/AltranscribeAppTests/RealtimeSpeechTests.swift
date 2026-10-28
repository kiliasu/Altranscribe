import XCTest
@preconcurrency import AVFoundation
@testable import Altranscribe
import AltranscribeCore

private actor LiveProbe {
    var lines: [TranscriptSegment] = []
    var firstPartial: Double?
    var firstFinal: Double?
    let start = Date()
    func receive(_ finalized: [TranscriptSegment], partial: TranscriptSegment? = nil) {
        if partial != nil && firstPartial == nil { firstPartial = Date().timeIntervalSince(start) }
        if !finalized.isEmpty && firstFinal == nil { firstFinal = Date().timeIntervalSince(start) }
        if ProcessInfo.processInfo.environment["ALTRANSCRIBE_LIVE_TRACE"] == "1" {
            print("UPDATE \(Date().timeIntervalSince(start)) final=\(finalized.map(\.text)) partial=\(partial?.text ?? "")")
        }
        for line in finalized {
            if let index = lines.firstIndex(where: { $0.id == line.id }) { lines[index] = line }
            else { lines.append(line) }
        }
    }
}

@MainActor final class RealtimeSpeechTests: XCTestCase {
    func testQuietPacedAudioAcrossLocalEngines() async throws {
        guard let models = ProcessInfo.processInfo.environment["ALTRANSCRIBE_REALTIME_MODELS"],
              let file = ProcessInfo.processInfo.environment["ALTRANSCRIBE_TEST_AUDIO"] else {
            throw XCTSkip("Opt in with installed models and a retained speech fixture; no downloads or playback.")
        }
        let directory = URL(fileURLWithPath: models)
        let decoder = MediaDecoder()
        _ = try await decoder.open(URL(fileURLWithPath: file))
        var source: [Float] = []
        while let part = try await decoder.next() { source += part.samples }
        await decoder.cancel()
        let only = ProcessInfo.processInfo.environment["ALTRANSCRIBE_REALTIME_ENGINE"]
        for provider in [SpeechProvider.whisper, .fluidAudio, .nemotron, .appleSpeech] where only == nil || provider.rawValue == only {
            let whisper = NativeWhisper(), fluid = NativeFluidAudio(), nemotron = NativeNemotron(), apple = NativeAppleSpeech()
            var settings = AppSettings(); settings.speechProvider = provider
            switch provider {
            case .whisper: try await whisper.load(model: directory.appendingPathComponent("ggml-tiny.bin").path, useGPU: true, live: true)
            case .fluidAudio: try await fluid.load(model: .english, models: directory, live: true)
            case .nemotron: try await nemotron.load(model: settings.nemotronModel, directory: settings.nemotronModel.directory(in: directory), language: "en", live: true)
            case .appleSpeech: try await apple.load(locale: "en-US")
            default: break
            }
            let probe = LiveProbe()
            if provider == .appleSpeech {
                try await apple.startLive(vocabulary: "") { await probe.receive($0.finalized, partial: $0.partial) }
            }
            var chunker = LiveAudioChunker(seconds: settings.liveChunkSeconds, automatic: settings.usesBatchLiveAudio)
            var gain = AdaptiveInputGain()
            let started = Date()
            func process(_ chunk: AudioChunk) async throws {
                if ProcessInfo.processInfo.environment["ALTRANSCRIBE_LIVE_TRACE"] == "1" { print("CHUNK \(chunk.start) \(chunk.duration) speech=\(chunk.containsSpeech)") }
                switch provider {
                case .whisper: await probe.receive(try await whisper.transcribe(chunk, language: "en", vocabulary: ""))
                case .fluidAudio: await probe.receive(try await fluid.transcribe(chunk))
                case .nemotron:
                    let update = try await nemotron.accept(chunk)
                    await probe.receive(update.finalized, partial: update.partial)
                case .appleSpeech: try await apple.acceptLive(chunk)
                default: break
                }
            }
            for offset in stride(from: 0, to: source.count, by: 1_600) {
                let end = min(source.count, offset + 1_600)
                // -28 dB source attenuation emulates low level input. No speaker or audio device is used.
                let samples = gain.process(source[offset..<end].map { $0 * 0.04 })
                for chunk in chunker.append(samples) { try await process(chunk) }
                let wait = Double(end) / 16_000 - Date().timeIntervalSince(started)
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            }
            if let tail = chunker.flush() { try await process(tail) }
            if provider == .nemotron { await probe.receive(try await nemotron.finish().finalized) }
            if provider == .appleSpeech { try await apple.finishLive() }
            let lines = await probe.lines
            let text = lines.map(\.text).joined(separator: " ").lowercased()
            let first = await probe.firstFinal ?? .infinity
            print("LIVE \(provider.rawValue): firstFinal=\(first), partial=\(await probe.firstPartial ?? -1), text=\(text)")
            if [.nemotron, .appleSpeech].contains(provider) {
                let partial = await probe.firstPartial ?? .infinity
                XCTAssertLessThan(partial, 4, "Streaming must display text without forcing a premature sentence boundary")
            } else { XCTAssertLessThan(first, 8, "A first stable phrase must arrive before the previous 8-second batch") }
            XCTAssertTrue(text.contains("ask not"), text)
            if provider == .nemotron { XCTAssertTrue(text.contains("americans"), "Do not split word pieces across captions: " + text) }
            XCTAssertTrue(text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).hasSuffix("country"), text)
            XCTAssertTrue(lines.allSatisfy { $0.start >= 0 && $0.end <= Double(source.count) / 16_000 + 0.05 })
            if [.nemotron, .appleSpeech].contains(provider) { let partial = await probe.firstPartial; XCTAssertNotNil(partial) }
            await whisper.unload(); await fluid.unload(); await nemotron.unload(); await apple.unload()
        }
    }
    func testNemotronRetainsFirstSentenceAfterSilentStereoCapture() async throws {
        guard let file = ProcessInfo.processInfo.environment["ALTRANSCRIBE_TEST_AUDIO"],
              let models = ProcessInfo.processInfo.environment["ALTRANSCRIBE_REALTIME_MODELS"] else {
            throw XCTSkip("Opt in with installed models and a JFK speech fixture")
        }
        let decoder = MediaDecoder(); _ = try await decoder.open(URL(fileURLWithPath: file))
        var source = [Float](repeating: 0, count: 160_000)
        while let chunk = try await decoder.next() { source += chunk.samples.map { $0 * 0.04 } }
        await decoder.cancel()
        let sink = CaptureSink(chunkSeconds: 0.32, adaptiveGain: true) { _, _ in }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        for offset in stride(from: 0, to: source.count * 3, by: 2_048) {
            let count = min(2_048, source.count * 3 - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 { for i in 0..<count { buffer.floatChannelData![channel][i] = source[(offset + i) / 3] } }
            sink.microphone(buffer)
        }
        await sink.finish()
        let engine = NativeNemotron(), model = AppSettings().nemotronModel
        try await engine.load(model: model, directory: model.directory(in: URL(fileURLWithPath: models)), language: "en", live: true)
        let probe = LiveProbe()
        for try await chunk in sink.stream { await probe.receive(try await engine.accept(chunk).finalized) }
        await probe.receive(try await engine.finish().finalized)
        let lines = await probe.lines
        let text = lines.map(\.text).joined(separator: " ").lowercased()
        let opening = text.components(separatedBy: "for you").first ?? text
        XCTAssertTrue(opening.contains("americans"), text)
        XCTAssertTrue(opening.contains("ask not"), "The first utterance must not lose words after initial silence: " + text)
        XCTAssertGreaterThan(lines.first?.start ?? 0, 9, "Skipping encoder silence must retain capture timestamps")
        XCTAssertTrue(text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).hasSuffix("country"), text)
        await engine.unload()
    }

}
