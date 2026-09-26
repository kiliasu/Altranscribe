# Speech models

English | [简体中文](../zh-CN/models.md) · [Home](../../README.md)

Download models under **Settings → Speech models**. Select the model and save when the download finishes. Downloads show progress and support cancellation and retry; retries start from the beginning. Exiting the app stops the download.

On Windows, models are stored in `%LOCALAPPDATA%\Altranscribe\models\`, the folder shown in the model panel.

## Adding Whisper models manually

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

App downloads verify the pinned version's file size and SHA-256. Manually added files are checked only for filename, size, and file header. Downloading a model does not install the Whisper program; configure `whisper-server.exe` separately. Whisper runs only on Windows; on Android, use Nemotron, a Windows host or a cloud service.

The bundled [Silero VAD](third-party.md#silero-vad) is copied to the model directory when local Whisper starts. It detects speech and is not a selectable transcription model.

## Nemotron streaming models

Besides Whisper, the same panel offers two NVIDIA Nemotron streaming transducers, run on the CPU through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). They decode as audio arrives, so live captions appear within about a second and do not flicker; quiet or distant speech is brought up to a working level before decoding. Each is about 0.7 GB and is stored as a folder in the model directory, on Windows and on Android.

| Model | Languages | License |
| --- | --- | --- |
| [Nemotron Speech Streaming EN 0.6B](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) | English only | [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/) |
| [Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) | 35 languages with automatic detection, at lower accuracy | [OpenMDW 1.1](https://openmdw.ai/license/1-1/) |

The files are the int8 exports from the sherpa-onnx `asr-models` release (560 ms chunks), fetched from their Hugging Face mirror at a pinned revision and verified by SHA-256. On quiet recordings, Whisper Large v3 Turbo still gives the more complete transcript; the English Nemotron model comes close and the multilingual one trails. Nemotron needs no GPU and no whisper-server, and it is the only local engine on Android.

