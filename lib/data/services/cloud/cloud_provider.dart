enum CloudProvider { openAI, gemini }

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
  String get label => this == CloudProvider.openAI ? 'OpenAI' : 'Google Gemini';
  Uri get base => Uri.parse(
    this == CloudProvider.openAI
        ? 'https://api.openai.com'
        : 'https://generativelanguage.googleapis.com',
  );
}

// The ASR model's published BCP-47 identifiers differ from UI language codes.
String geminiLanguage(String language) => switch (language) {
  'zh' => 'cmn-Hans-CN',
  'en' => 'en-US',
  'ja' => 'ja-JP',
  'ko' => 'ko-KR',
  _ => language,
};
