# Speech models

English | [简体中文](../zh-CN/models.md) · [Home](../../README.md)

Download models under **Settings → Speech models**, then select the model and save. Progress also shows on the start page, and the download continues after the panel closes; on Android it keeps running in the background with a notification. A dropped connection resumes where it stopped, and so does downloading again after the app was closed; cancelling deletes the partial file. The delete button next to a model removes its files.

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

The bundled [Silero VAD](third-party.md#silero-vad) is copied to the model directory when local Whisper starts. It detects speech and is not a selectable transcription model. The app also runs it itself to cut files at pauses: Whisper hears 30 seconds at a time, so each piece ends in the last pause before that. Audio far below normal speech level, such as a distant lecture, is raised before Whisper hears it; its speech detector is strict enough to ignore notification sounds and would otherwise drop nearly all such speech.

## Nemotron streaming models

Besides Whisper, the same panel offers two NVIDIA Nemotron streaming transducers, run on the CPU through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). They decode as audio arrives, so live captions appear within about a second and do not flicker; quiet or distant speech is brought up to a working level before decoding. Each is about 0.7 GB and is stored as a folder in the model directory, on Windows and on Android.

| Model | Languages | License |
| --- | --- | --- |
| [Nemotron Speech Streaming EN 0.6B](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) | English only | [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/) |
| [Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) | 35 languages with automatic detection, at lower accuracy | [OpenMDW 1.1](https://openmdw.ai/license/1-1/) |

The files are the int8 exports from the sherpa-onnx `asr-models` release (560 ms chunks), fetched from their Hugging Face mirror at a pinned revision and verified by SHA-256. On quiet recordings, Whisper Large v3 Turbo still gives the more complete transcript; the English Nemotron model comes close and the multilingual one trails. Nemotron needs no GPU and no whisper-server, and it is the only local engine on Android.

## Nemotron 3.5 Transcribe

[Nemotron 3.5 Transcribe](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B) is NVIDIA's speech language model for complete recordings: 30B parameters, of which about 4B are active at a time. It writes punctuation itself and times every word. It is most accurate in English; Chinese is in NVIDIA's lowest quality tier, so compare it with Whisper on your own recordings.

It runs on Windows in [NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp), NVIDIA's local runtime, installed separately: run its Windows installer or extract the `windows-x86_64-cuda` archive from its releases, then enter `nemo-speech.exe` under **Transcribe executable**. The installer's default location is found automatically.

The model is the NVFP4 build, about 21.3 GB in two files: the decoder and the speech encoder it names. NVIDIA publishes no GGUF files (its own NVFP4 checkpoint runs only in vLLM on Linux), so the app downloads [AtomicChat's conversion](https://huggingface.co/AtomicChat/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-GGUF), made with NVIDIA's converter, at a pinned revision and verifies it by SHA-256. License: [OpenMDW 1.1](https://openmdw.ai/license/1-1/).

NVFP4 needs a Blackwell GPU, and the model needs about 29 GB of GPU memory for a long recording, so in practice a 32 GB card such as the RTX 5090; the app checks before starting and says when something else, such as a local LLM, holds the memory. On an RTX 5090 it loads in under 20 seconds and transcribes a 58-minute lecture in about 35 seconds. Files are cut at pauses into pieces of up to 55 minutes, and each line keeps the time of its own words. A local text model and Transcribe do not fit in the GPU together, so they take turns. All selected files are transcribed first; the text model for cleanup, translation and summaries loads once Transcribe has left the GPU, and a local model already loaded is unloaded before Transcribe starts. In live sessions, which Transcribe handles in the same short windows as Whisper, a local text model translates and summarizes once the session stops; choose a cloud model under **Settings → Translation & LLM** to translate as you speak. Transcribe's model settings can instead run the local model beside it; Transcribe then loads first, and the start page shows the estimated GPU memory and warns when it may run short. Transcribe does not run on Android.
