import Foundation

/// File Transcriptions API models, checked against OpenAI's reference on 2026-10-25.
/// Realtime-only models require a different transport and are not file-model presets.
public enum OpenAITranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case transcribe = "gpt-transcribe"
    case transcribe4o = "gpt-4o-transcribe"
    case mini = "gpt-4o-mini-transcribe"
    case miniSnapshot = "gpt-4o-mini-transcribe-2025-12-15"
    case whisper = "whisper-1"
    case diarize = "gpt-4o-transcribe-diarize"

    public var id: String { rawValue }
    public var supportsVocabulary: Bool { self != .diarize }
    public var isDeprecated: Bool { self != .transcribe }
}

/// General text models from the providers' official catalogs, checked on 2026-10-25.
public enum TextModelPresets {
    public static let openAI = ["gpt-6.1-sol", "gpt-6-luna", "gpt-6-astra"]
    /// 3.5 Flash-Lite leads because it is the preset that completed real requests on 2026-10-25;
    /// 3.8 Flash, the newer recommendation, returned 503 or timed out that day and stays selectable.
    public static let gemini = ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-4-argon"]
    public static let anthropic = ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"]
}
