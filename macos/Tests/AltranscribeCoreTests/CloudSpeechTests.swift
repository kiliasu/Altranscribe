import XCTest
@testable import AltranscribeCore

final class CloudSpeechTests: XCTestCase {
    func testOpenAIReconcilesFinalsAndDrainsBilingualOutput() throws {
        var state = CloudSpeechState(provider: .compatible, direct: false)
        state.accept(AudioChunk(samples: Array(repeating: 0.1, count: 64_000), start: 10)); state.commit()
        let event: [String: Any] = ["type": "conversation.item.input_audio_transcription.completed", "item_id": "turn", "transcript": "Final words."]
        let early = try XCTUnwrap(state.receive(event).first)
        let committed = try XCTUnwrap(state.receive(["type": "input_audio_buffer.committed", "item_id": "turn"]).first)
        XCTAssertEqual(early.segment.id, committed.segment.id)
        XCTAssertEqual(committed.segment.start, 10); XCTAssertEqual(committed.segment.end, 14)
        XCTAssertEqual(state.pending, 0)
        XCTAssertTrue(state.receive(event).isEmpty)
        XCTAssertTrue(state.receive(["type": "conversation.item.input_audio_transcription.delta", "item_id": "turn", "delta": "duplicate"]).isEmpty)

        var translated = CloudSpeechState(provider: .compatible, direct: true)
        translated.accept(AudioChunk(samples: [0.1], start: 30))
        let output = try XCTUnwrap(translated.receive(["type": "session.output_transcript.delta", "delta": "你好", "elapsed_ms": 100]).first)
        let input = try XCTUnwrap(translated.receive(["type": "session.input_transcript.delta", "delta": "Hello", "elapsed_ms": 100]).first)
        XCTAssertEqual(output.segment.id, input.segment.id)
        let final = try XCTUnwrap(translated.receive(["type": "session.closed", "error": NSNull()]).first)
        XCTAssertTrue(translated.closed); XCTAssertTrue(final.finalized)
        XCTAssertEqual(final.segment.text, "Hello"); XCTAssertEqual(final.segment.translation, "你好")
    }

    func testGeminiInterimReplacementCompletionAndExpiry() throws {
        var state = CloudSpeechState(provider: .gemini, direct: false)
        state.accept(AudioChunk(samples: Array(repeating: 0.1, count: 1600), start: 600))
        state.endActivity()
        let first = try XCTUnwrap(state.receive(["serverContent": ["interimInputTranscription": ["text": "hel"]]]).first)
        let next = try XCTUnwrap(state.receive(["serverContent": ["interimInputTranscription": ["text": "hello"]]]).first)
        let final = try XCTUnwrap(state.receive(["serverContent": ["inputTranscription": ["text": "hello world"]]]).first)
        // A silent activity can close while the preceding turn's completion is still in flight.
        state.accept(AudioChunk(samples: Array(repeating: 0, count: 1600), start: 600.1)); state.endActivity()
        XCTAssertTrue(state.awaitingOutput)
        _ = state.receive(["serverContent": ["generationComplete": true]])
        XCTAssertEqual(state.pending, 0, "Gemini activities are not counted; the service answers only the ones with speech")
        XCTAssertEqual(first.segment.id, next.segment.id); XCTAssertEqual(first.segment.id, final.segment.id)
        XCTAssertEqual(next.segment.text, "hello"); XCTAssertEqual(final.segment.text, "hello world")
        XCTAssertTrue(final.finalized); XCTAssertFalse(state.awaitingOutput); XCTAssertFalse(state.mayOweText)
        _ = state.receive(["goAway": ["timeLeft": "45.5s"]]); XCTAssertEqual(state.expiringIn, 45.5)
        var settings = AppSettings(); settings.speechProvider = .gemini; settings.translate = true
        let setup = try XCTUnwrap(settings.cloudSetup()["setup"] as? [String: Any])
        XCTAssertNotNil(setup["inputAudioTranscription"]); XCTAssertNotNil(setup["outputAudioTranscription"])
        let generation = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        XCTAssertNil(generation["inputAudioTranscription"])
        XCTAssertEqual(generation["responseModalities"] as? [String], ["AUDIO"])
        settings.translate = false; settings.sourceLanguage = "zh"; settings.vocabulary = "Swift"
        let asr = try XCTUnwrap(settings.cloudSetup()["setup"] as? [String: Any])
        let activity = (asr["realtimeInputConfig"] as? [String: Any])?["automaticActivityDetection"] as? [String: Bool]
        XCTAssertEqual(activity?["disabled"], true)
        let config = try XCTUnwrap(asr["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(config["languageCodes"] as? [String], ["cmn-Hans-CN"])
        XCTAssertEqual(config["customVocabulary"] as? [String], ["Swift"])
        for provider in [SpeechProvider.compatible, .gemini] {
            settings.speechProvider = provider; settings.translate = true
            settings.vocabulary = Array(repeating: "term", count: 1001).joined(separator: ",")
            XCTAssertFalse(settings.supportsVocabulary(live: true))
            XCTAssertFalse(settings.offersLanguageChoice(live: true))
            XCTAssertTrue(settings.supportsVocabulary(live: false))
            XCTAssertTrue(settings.offersLanguageChoice(live: false))
            XCTAssertNoThrow(try settings.cloudSetup(), "Hidden, unused terms must not block direct translation")
            settings.translate = false
            XCTAssertTrue(settings.supportsVocabulary(live: true))
            if provider == .gemini { XCTAssertThrowsError(try settings.cloudSetup()) }
        }
        settings.speechProvider = .compatible; settings.speechModel = OpenAITranscriptionModel.diarize.id
        XCTAssertFalse(settings.supportsVocabulary(live: false))
        XCTAssertTrue(settings.supportsVocabulary(live: true), "A file model must not hide the live model's supported terms")
        for provider in [SpeechProvider.nemotron, .fluidAudio, .whisper, .appleSpeech] {
            settings.speechProvider = provider
            let supported = provider == .whisper || provider == .appleSpeech
            XCTAssertEqual(settings.supportsVocabulary(live: false), supported)
            XCTAssertEqual(settings.supportsVocabulary(live: true), supported)
        }
    }
}
