# Whisper models

English | [简体中文](../zh-CN/models.md) · [Home](../../README.md)

On Windows, download models under **Settings → Whisper models**. Select the model and save when the download finishes. Downloads show progress and support cancellation and retry; retries start from the beginning. Exiting the app stops the download.

Models are stored in `%LOCALAPPDATA%\Altranscribe\models\`, the folder shown in the model panel.

## Adding models manually

Place an official file from the table below in the model directory, then open model settings or click refresh. Do not rename `.en` or quantized variants to these filenames.

| Model | Filename | Approximate size |
| --- | --- | ---: |
| Tiny | ggml-tiny.bin | 78 MB |
| Base | ggml-base.bin | 148 MB |
| Small | ggml-small.bin | 488 MB |
| Medium | ggml-medium.bin | 1.53 GB |
| Large v3 | ggml-large-v3.bin | 3.10 GB |
| Large v3 Turbo | ggml-large-v3-turbo.bin | 1.62 GB |

Sources: the [official whisper.cpp model instructions](https://github.com/ggml-org/whisper.cpp/tree/master/models) and the [Hugging Face repository they reference](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1).

App downloads verify the pinned version's file size and SHA-256. Manually added files are checked only for filename, size, and file header. Downloading a model does not install the Whisper program; configure `whisper-server.exe` separately. Android uses remote or cloud inference and does not offer local model downloads.

The bundled [Silero VAD](third-party.md#silero-vad) is copied to the model directory when local Whisper starts. It detects speech and is not a selectable transcription model.
