# Bundled voice activity detector

`ggml-silero-v5.1.2.bin` is the 885,098-byte Silero VAD model distributed by
[ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad), revision
`9ffd54a1e1ee413ddf265af9913beaf518d1639b`. SHA-256:
`29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf`.

Source: [Silero VAD](https://github.com/snakers4/silero-vad), MIT license in
`Silero-LICENSE.txt`. Whisper copies the bundled model into the configured models
directory before starting; this does not require a network connection. The model
is an internal speech detector and is not an ASR model in the Whisper selector.
