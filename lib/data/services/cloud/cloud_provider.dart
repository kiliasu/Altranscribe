enum CloudProvider { openAI, gemini, anthropic }

enum SpeechProvider { whisper, openAI, gemini }

extension SpeechProviderInfo on SpeechProvider {
  CloudProvider get cloud => this == SpeechProvider.openAI
      ? CloudProvider.openAI
      : CloudProvider.gemini;
  String get label => switch (this) {
    SpeechProvider.whisper => 'Whisper · Local',
    SpeechProvider.openAI => 'OpenAI',
    SpeechProvider.gemini => 'Google Gemini',
  };
  String liveModel(bool translate) => switch (this) {
    SpeechProvider.whisper => 'whisper.cpp',
    SpeechProvider.openAI =>
      translate ? 'gpt-realtime-translate' : 'gpt-live-transcribe',
    SpeechProvider.gemini =>
      translate
          ? 'gemini-3.5-live-translate-preview'
          : 'gemini-3.5-transcribe-live',
  };
  String get fileModel => this == SpeechProvider.openAI
      ? 'gpt-transcribe'
      : 'gemini-3.5-transcribe';
}

extension CloudProviderInfo on CloudProvider {
  String get label => switch (this) {
    CloudProvider.openAI => 'OpenAI',
    CloudProvider.gemini => 'Google Gemini',
    CloudProvider.anthropic => 'Anthropic',
  };
  Uri get base => Uri.parse(switch (this) {
    CloudProvider.openAI => 'https://api.openai.com',
    CloudProvider.gemini => 'https://generativelanguage.googleapis.com',
    CloudProvider.anthropic => 'https://api.anthropic.com',
  });
}

// The ASR model's published BCP-47 identifiers differ from UI language codes.
String geminiLanguage(String language) => switch (language) {
  'zh' => 'cmn-Hans-CN',
  'en' => 'en-US',
  'ja' => 'ja-JP',
  'ko' => 'ko-KR',
  _ => language,
};
