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
        case .compatible: "OpenAI"
        case .gemini: "Google Gemini"
        }
    }
    public var isLocal: Bool { self != .compatible && self != .gemini }
}

public enum TextProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case compatible, gemini, anthropic, apple
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .compatible: L("OpenAI / Ollama / Compatible")
        case .gemini: "Google Gemini"
        case .anthropic: "Anthropic"
        case .apple: L("Apple Intelligence · On Device")
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
    public var geminiSpeechModel = "gemini-3.5-transcribe"
    public var cloudDirectTranslation: Bool?
    public var textProvider: TextProvider = .compatible
    public var textBaseURL = "http://127.0.0.1:11434/v1"
    public var textModel = ""
    public var textModelOverride: String?
    public var anthropicWorkspaceID: String?
    /// The model last chosen for each text service, so switching services and back restores it.
    public var textModels: [String: String]?
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
    public var effectiveGeminiSpeechModel: String {
        // Earlier versions used a general-purpose model with a transcription prompt.
        ["gemini-2.5-flash", "gemini-2.5-pro"].contains(geminiSpeechModel) ? "gemini-3.5-transcribe" :
            geminiSpeechModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var vocabularyTerms: [String] {
        vocabulary.components(separatedBy: CharacterSet(charactersIn: ",，\r\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    public var geminiLanguage: String {
        switch sourceLanguage {
        case "zh": "cmn-Hans-CN"
        case "en": "en-US"
        case "ja": "ja-JP"
        case "ko": "ko-KR"
        case "es": "es-US"
        case "fr": "fr-FR"
        case "de": "de-DE"
        case "pt": "pt-BR"
        case "it": "it-IT"
        case "ru": "ru-RU"
        case "ar": "ar-EG"
        case "hi": "hi-IN"
        default: sourceLanguage
        }
    }
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
        case .apple: ""
        }
    }
    public var effectiveTextModel: String {
        textProvider == .apple ? NativeAppleText.modelName : (textModelOverride ?? textModel).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var textModelPresets: [String] {
        switch textProvider {
        case .compatible:
            URL(string: textBaseURL)?.host?.lowercased() == "api.openai.com" ? TextModelPresets.openAI : []
        case .gemini: TextModelPresets.gemini
        case .anthropic: TextModelPresets.anthropic
        case .apple: []
        }
    }
    // MARK: Presentation shared by the home page, the inspectors and the settings pages.

    /// The speech service as a user would name it: the official provider, or a compatible service by host.
    public var speechServiceTitle: String {
        guard speechProvider == .compatible else { return speechProvider.title }
        let host = URL(string: speechBaseURL)?.host?.lowercased() ?? ""
        if host == "api.openai.com" { return "OpenAI" }
        return (isLoopback(speechBaseURL) ? L("Local Service") : L("Compatible Service")) + (host.isEmpty ? "" : " · " + host)
    }
    /// The model a session would use, in the words the settings pages use.
    public func speechModelTitle(live: Bool) -> String {
        switch speechProvider {
        case .whisper:
            guard !effectiveModelPath.isEmpty else { return L("No model selected") }
            let file = URL(fileURLWithPath: effectiveModelPath).lastPathComponent
            return WhisperModel.catalog.first { $0.filename == file }?.title ?? file
        case .nemotron: return nemotronModel.multilingual ? L("Nemotron 3.5 · Multilingual") : L("Nemotron · English")
        case .fluidAudio: return fluidAudioModel.title
        case .appleSpeech: return InterfaceLanguage.current.locale.localizedString(forIdentifier: appleSpeechLocale) ?? appleSpeechLocale
        case .gemini: return live ? liveSpeechModel : effectiveGeminiSpeechModel
        case .compatible: return live && usesCloudLive ? liveSpeechModel : effectiveSpeechModel
        }
    }
    /// Engine and model in one short phrase, without repeating the engine when the model's name already says it.
    public func speechSummary(live: Bool) -> String {
        switch speechProvider {
        case .whisper: "Whisper · " + speechModelTitle(live: live)
        case .nemotron, .fluidAudio: speechModelTitle(live: live)
        case .appleSpeech: "Apple · " + speechModelTitle(live: live)
        case .compatible, .gemini: speechServiceTitle + " · " + speechModelTitle(live: live)
        }
    }
    /// Records keep model identifiers; show them the way the settings name them.
    public static func speechModelDisplayName(_ stored: String) -> String {
        if let nemotron = NemotronModel.catalog.first(where: { $0.id == stored }) {
            return nemotron.multilingual ? L("Nemotron 3.5 · Multilingual") : L("Nemotron · English")
        }
        if let fluid = FluidAudioModel(rawValue: stored) { return fluid.title }
        return stored
    }
    public var textServiceTitle: String {
        guard textProvider == .compatible else { return textProvider.title }
        let host = URL(string: textBaseURL)?.host?.lowercased() ?? ""
        if host == "api.openai.com" { return "OpenAI" }
        return (isLoopback(textBaseURL) ? L("Local Service") : L("Compatible Service")) + (host.isEmpty ? "" : " · " + host)
    }
    /// Engines whose spoken language the user picks; the others fix it through the chosen model or locale.
    public var offersLanguageChoice: Bool {
        speechProvider == .whisper || !speechProvider.isLocal || (speechProvider == .nemotron && nemotronModel.multilingual)
    }
    /// Translation of files and summaries always need the text service; live direct translation does not.
    public func needsTextModel(live: Bool) -> Bool { (translate && !(live && usesDirectSpeechTranslation)) || summarize }
    public func textModelMissing(live: Bool) -> Bool { needsTextModel(live: live) && effectiveTextModel.isEmpty }
    private func isLoopback(_ url: String) -> Bool { (try? APIEndpoint(url).isLoopback) == true }

    var textModelKey: String {
        textProvider == .compatible ? "compatible:" + ((try? APIEndpoint(textBaseURL).base.absoluteString) ?? textBaseURL) : textProvider.rawValue
    }
    /// Change the text service or its address, keeping the model chosen for the service being left and
    /// restoring the one chosen earlier for the service being entered, or its first preset.
    public mutating func switchTextService(provider: TextProvider? = nil, baseURL: String? = nil) {
        var memory = textModels ?? [:]
        if !effectiveTextModel.isEmpty { memory[textModelKey] = effectiveTextModel }
        if let provider { textProvider = provider }
        if let baseURL { textBaseURL = baseURL }
        textModel = memory[textModelKey] ?? textModelPresets.first ?? ""
        textModelOverride = nil
        textModels = memory
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
