import XCTest
@testable import AltranscribeCore

final class LiveAudioTests: XCTestCase {
    func testSentenceBoundariesKeepThoughtsAndMergeShortContinuations() {
        let words = ["So", " we're", " gonna", " use", " these", " to", " do", " more", " control."]
        let times = words.indices.map { Double($0) * 0.7 }
        XCTAssertNil(SpeechSentenceBoundary.cut(tokens: words.prefix(6), times: times.prefix(6), quiet: 0, closing: false),
                     "Three seconds of transport must not finalize an unfinished sentence")
        XCTAssertNil(SpeechSentenceBoundary.cut(tokens: words.prefix(6), times: times.prefix(6), quiet: 1.5, closing: false),
                     "A hesitation after 'to' is not a sentence boundary")
        XCTAssertEqual(SpeechSentenceBoundary.cut(tokens: words[...], times: times[...], quiet: 0.5, closing: false), words.count)
        let combined = words + [" The", " destination", " tells", " the", " source"]
        XCTAssertEqual(SpeechSentenceBoundary.cut(tokens: combined[...], times: combined.indices.map(Double.init)[...], quiet: 0, closing: false), words.count)
        let fragment = TranscriptSegment(start: 0, end: 2, text: "the maximum number of")
        XCTAssertTrue(SpeechSentenceBoundary.shouldMerge(fragment, nextStart: 2.3))
        XCTAssertFalse(SpeechSentenceBoundary.shouldMerge(fragment, nextStart: 7))
        XCTAssertFalse(SpeechSentenceBoundary.shouldMerge(TranscriptSegment(start: 0, end: 2, text: "That is correct."), nextStart: 2.3))
        XCTAssertFalse(SpeechSentenceBoundary.isComplete("Ask Dr."))
        let continuous = ["We"] + Array(repeating: " continue", count: 70)
        let cut = SpeechSentenceBoundary.cut(tokens: continuous[...], times: continuous.indices.map { Double($0) * 0.3 }[...], quiet: 0, closing: false)
        XCTAssertEqual(cut, continuous.count - 1, "Bound an unpunctuated passage while retaining its last word as a hypothesis")
        XCTAssertEqual(SpeechSentenceBoundary.cut(tokens: words.prefix(3), times: times.prefix(3), quiet: 0, closing: true), 3)
    }

    func testChunkBoundariesGainAndLegacySettings() throws {
        let voice = (0..<24_000).map { Float(sin(Double($0) * 0.1)) * 0.003 }
        let samples = voice + voice + [Float](repeating: 0, count: 8_000) + voice
        var automatic = LiveAudioChunker(seconds: 4, automatic: true)
        var chunks: [AudioChunk] = []
        for offset in stride(from: 0, to: samples.count, by: 147) {
            chunks += automatic.append(Array(samples[offset..<min(samples.count, offset + 147)]))
        }
        if let tail = automatic.flush() { chunks.append(tail) }
        XCTAssertEqual(chunks.flatMap(\.samples), samples, "Pause cuts and the final tail must retain every sample exactly once")
        XCTAssertEqual(chunks[0].duration, 3.3, accuracy: 0.021, "Automatic mode should cut at the observed pause before its 4-second cap")
        XCTAssertEqual(chunks.last!.start + chunks.last!.duration, Double(samples.count) / 16_000, accuracy: 0.00001)
        var fixed = LiveAudioChunker(seconds: 2)
        let fixedChunks = fixed.append(samples)
        XCTAssertEqual(fixedChunks.first?.duration, 2)
        var gain = AdaptiveInputGain()
        let quiet = gain.process(voice)
        func rms(_ x: [Float]) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count)) }
        XCTAssertGreaterThan(rms(Array(quiet.suffix(8_000))), rms(voice) * 4)
        let loud = gain.process(voice.map { $0 * 300 })
        XCTAssertLessThanOrEqual(loud.map(abs).max()!, 0.951, "Sudden close/loud speech must not clip after amplification")
        _ = gain.process([Float](repeating: 0, count: 16_000))
        XCTAssertLessThan(gain.process([Float](repeating: 0, count: 320)).map(abs).max()!, 0.000001)
        var noiseGain = AdaptiveInputGain()
        let noise = voice.map { $0 / 100 }
        XCTAssertLessThanOrEqual(rms(noiseGain.process(noise)), rms(noise) * 1.1, "Do not lift near-silent noise")
        var tail = LiveBatchTail()
        _ = tail.input(AudioChunk(samples: voice + voice, start: 0))
        let earlier = TranscriptSegment(start: 0, end: 3, text: "Earlier sentence")
        _ = tail.results([earlier])
        // A skipped silence window must not retain the preceding sentence's IDs.
        _ = tail.input(AudioChunk(samples: [Float](repeating: 0, count: 64_000), start: 3, containsSpeech: false))
        _ = tail.input(AudioChunk(samples: Array(voice.prefix(8_000)), start: 7))
        let ending = TranscriptSegment(start: 7, end: 7.5, text: "Last word")
        XCTAssertEqual(tail.results([ending]).map(\.id), [ending.id])
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings()))
        XCTAssertNil(settings.liveChunkMode); XCTAssertNil(settings.captionSentenceCount)
        XCTAssertEqual(settings.visibleCaptionCount, 3)
        var batch = settings; batch.speechProvider = .whisper
        XCTAssertEqual(batch.liveChunkSeconds, 4)
        batch.liveChunkMode = .long; XCTAssertEqual(batch.liveChunkSeconds, 8)
        batch.speechProvider = .appleSpeech; XCTAssertEqual(batch.liveChunkSeconds, 0.1)
    }
}
