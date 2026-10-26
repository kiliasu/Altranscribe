import Foundation

public struct AppError: LocalizedError, Sendable {
    public let message: LocalizedText
    public init(_ key: String, _ arguments: String...) { message = LocalizedText(key: key, arguments: arguments) }
    public var errorDescription: String? { message.text }
}

public enum AudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone, system, file
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .microphone: L("Microphone")
        case .system: L("System Audio")
        case .file: L("Media File")
        }
    }
    public var symbol: String {
        switch self { case .microphone: "mic"; case .system: "speaker.wave.2"; case .file: "doc.text" }
    }
}

public enum SpeechProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case whisper, nemotron, fluidAudio, appleSpeech, compatible, gemini
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .whisper: L("Whisper · On Device")
        case .nemotron: L("Nemotron · On Device")
        case .fluidAudio: L("FluidAudio · On Device")
        case .appleSpeech: "Apple SpeechTranscriber"
        case .compatible: L("OpenAI Transcription")
        case .gemini: "Google Gemini"
        }
    }
    public var isLocal: Bool { self != .compatible && self != .gemini }
}

public enum TextProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case compatible, gemini, anthropic
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .compatible: L("OpenAI / Ollama / Compatible")
        case .gemini: "Google Gemini"
        case .anthropic: "Anthropic"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var speechProvider: SpeechProvider = .nemotron
    public var modelPath = ""
    // Optional so settings saved before Nemotron was added still decode unchanged.
    public var nemotronModelID: String?
    // Optional fields preserve settings written by earlier app versions.
    public var fluidAudioModelID: String?
    public var appleSpeechLocaleID: String?
    public var useGPU = true
    public var speechBaseURL = "https://api.openai.com/v1"
    public var speechModel = "gpt-transcribe"
    public var speechModelOverride: String?
    public var geminiSpeechModel = "gemini-2.5-flash"
    public var textProvider: TextProvider = .compatible
    public var textBaseURL = "http://127.0.0.1:11434/v1"
    public var textModel = ""
    public var textModelOverride: String?
    public var sourceLanguage = "auto"
    public var targetLanguage = "zh"
    public var translate = false
    public var summarize = false
    public var vocabulary = ""
    public var captionSize = 24.0
    public var captionTranslationOnly = false
    public init() {}

    public var nemotronModel: NemotronModel {
        NemotronModel.catalog.first { $0.id == nemotronModelID } ?? NemotronModel.catalog[0]
    }
    public var recognitionLanguage: String {
        switch speechProvider {
        case .nemotron where !nemotronModel.multilingual: "en"
        case .fluidAudio: fluidAudioModel == .english ? "en" : "auto"
        case .appleSpeech: Locale(identifier: appleSpeechLocale).language.languageCode?.identifier ?? "en"
        default: sourceLanguage
        }
    }
    public var fluidAudioModel: FluidAudioModel { FluidAudioModel(rawValue: fluidAudioModelID ?? "") ?? .english }
    public var appleSpeechLocale: String { appleSpeechLocaleID ?? "en-US" }
    public var effectiveSpeechModel: String {
        (speechModelOverride ?? speechModel).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var openAITranscriptionModel: OpenAITranscriptionModel? { OpenAITranscriptionModel(rawValue: effectiveSpeechModel) }
    public var supportsVocabulary: Bool {
        switch speechProvider {
        case .nemotron, .fluidAudio: false
        case .compatible: openAITranscriptionModel?.supportsVocabulary ?? false
        default: true
        }
    }

    public var effectiveModelPath: String { modelPath }

    public var speechEndpoint: String {
        speechProvider == .gemini ? "https://generativelanguage.googleapis.com/v1beta" : speechBaseURL
    }
    public var textEndpoint: String {
        switch textProvider {
        case .compatible: textBaseURL
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .anthropic: "https://api.anthropic.com/v1"
        }
    }
    public var effectiveTextModel: String {
        (textModelOverride ?? textModel).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var textModelPresets: [String] {
        switch textProvider {
        case .compatible:
            URL(string: textBaseURL)?.host?.lowercased() == "api.openai.com" ? TextModelPresets.openAI : []
        case .gemini: TextModelPresets.gemini
        case .anthropic: TextModelPresets.anthropic
        }
    }
    public static var languages: [(String, String)] { [
        ("auto", L("Detect Automatically")), ("zh", "中文"), ("en", "English"),
        ("ja", "日本語"), ("ko", "한국어"), ("es", "Español"), ("fr", "Français"),
        ("de", "Deutsch"), ("pt", "Português"), ("it", "Italiano"), ("ru", "Русский"),
        ("ar", "العربية"), ("hi", "हिन्दी")
    ] }
}

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var start: Double
    public var end: Double
    public var text: String
    public var translation: String?
    public var translationError: LocalizedText?
    public var estimated = false
    public init(start: Double, end: Double, text: String, estimated: Bool = false) {
        self.start = start; self.end = end; self.text = text; self.estimated = estimated
    }
}

public enum RecordStatus: String, Codable, Sendable {
    case inProgress, completed, interrupted, failed
    public var title: String {
        switch self {
        case .inProgress: L("In Progress")
        case .completed: L("Completed")
        case .interrupted: L("Interrupted")
        case .failed: L("Processing Failed")
        }
    }
}

public struct TranscriptRecord: Codable, Equatable, Identifiable, Sendable {
    public var version = 2
    public var id = UUID()
    public var title: String
    public var createdAt = Date()
    public var source: AudioSource
    public var sourcePath: String?
    public var language: String
    public var targetLanguage: String?
    public var speechModel: String
    public var status: RecordStatus = .inProgress
    public var segments: [TranscriptSegment] = []
    public var summary: String?
    public var summaryLanguage: String?
    public var error: LocalizedText?
    public init(title: String, source: AudioSource, language: String, speechModel: String) {
        self.title = title; self.source = source; self.language = language; self.speechModel = speechModel
    }
    public var duration: Double { segments.last?.end ?? 0 }
    public var fullText: String { segments.map(\.text).joined(separator: "\n") }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || ([title, summary ?? ""] + segments.flatMap { [$0.text, $0.translation ?? ""] })
            .contains { $0.localizedStandardContains(query) }
    }
}

public func timestamp(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                        : String(format: "%02d:%02d", total / 60, total % 60)
}

public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var start: Double
    public var duration: Double { Double(samples.count) / 16_000 }
    public init(samples: [Float], start: Double) { self.samples = samples; self.start = start }
}
