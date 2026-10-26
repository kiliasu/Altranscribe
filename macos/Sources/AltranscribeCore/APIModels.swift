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
