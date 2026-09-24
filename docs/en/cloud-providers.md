# Cloud services

English | [简体中文](../zh-CN/cloud-providers.md) · [Home](../../README.md)

Windows and Android support OpenAI and Google Gemini without downloading cloud models. You need a provider API key, available quota, and access to the required models.

## Setup

1. Open **Settings → Whisper models**, select OpenAI or Gemini, and enter and save your API key.
2. Choose live transcription or direct live translation. File transcription uses the file model shown in the panel.
3. For text translation, titles, or summaries, choose a provider and text model under **Settings → Translation & LLM**. The same provider reuses the saved key.
4. Save, return to the home screen, choose your audio sources and languages, and start.

Transcription can be followed by a separate text translation step. Direct live translation returns both source text and translation, but titles and summaries still need a text model. Turning translation off switches live audio to transcription mode. Cloud processing detects the source language automatically by default; direct live translation only takes a target language.

Successfully listing models does not mean your account can call every model. For access or quota errors, check your provider account and the model names shown in the panel.

## Usage and charges

- Microphone and system audio use separate connections and are billed separately. Pausing stops new audio uploads.
- Direct live translation may generate translated speech. The provider may charge for it even though the app does not play it.
- Long files are submitted in sections; the original file is unchanged. Gemini file transcription temporarily uploads audio. The app attempts to delete it when the task ends and reports deletion failures.
- After **Stop & save**, final text, translations, and summaries continue processing. Wait for them to finish before starting another session.
- If the network disconnects or quota runs out, received text is retained. Paid inference is not retried automatically.

## Known limitations

Long Gemini sessions switch to new connections automatically. Switching can split words, so uninterrupted recognition is not guaranteed. The preview translation API may not send final confirmation; the transcript is marked unconfirmed in that case. Waiting after stopping cannot guarantee that all delayed final words arrive.

Timestamps and the grouping of source text and translations may be approximate. Review model output. Long-running capture from both audio sources depends on network stability and service limits.

API keys are encrypted with Windows DPAPI or Android Keystore and are not written to transcripts. Enter them again when changing users or devices. Audio and text are sent to the provider's official endpoints; consult the selected provider for charges and data handling terms.
