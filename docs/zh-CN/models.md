# 转录模型

[English](../en/models.md) | 简体中文 · [首页](../../README.zh-CN.md)

在「设置 → 模型选择」中下载模型。下载完成后选择模型并保存；支持进度显示、取消与重试，重试从头开始。应用关闭后下载会停止。

Windows 上的模型存放在 `%LOCALAPPDATA%\Altranscribe\models\`，也就是模型面板里显示的目录。

## 手动添加 Whisper 模型

将下表中的官方文件放入模型目录，打开模型设置或点击刷新。不要将 `.en` 或量化版本重命名为这些文件。

| 模型 | 文件名 | 大小（约） |
| --- | --- | ---: |
| Tiny | ggml-tiny.bin | 78 MB |
| Base | ggml-base.bin | 148 MB |
| Small | ggml-small.bin | 488 MB |
| Medium | ggml-medium.bin | 1.53 GB |
| Large v3 | ggml-large-v3.bin | 3.10 GB |
| Large v3 Turbo | ggml-large-v3-turbo.bin | 1.62 GB |

来源：[whisper.cpp 官方模型说明](https://github.com/ggml-org/whisper.cpp/tree/master/models)及其指定的 [Hugging Face 权重仓库](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1)。

应用下载会校验固定版本的文件大小与 SHA-256；手动添加时只检查文件名、大小和文件头。下载模型不包含 Whisper 运行程序，需另行配置 `whisper-server.exe`。Whisper 只在 Windows 上运行；Android 可以用 Nemotron、Windows 主机或云端服务。

随包附带的 [Silero VAD](third-party.md#silero-vad) 会在启动本地 Whisper 时复制到模型目录，用于语音检测，不属于可选转录模型。

## Nemotron 流式模型

除 Whisper 外，同一面板还提供两个 NVIDIA Nemotron 流式模型，通过 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 在 CPU 上运行。它们随音频到达即时解码，实时字幕约一秒内出现且不会闪动；安静或较远的声音会先自动增益再识别。每个模型约 0.7 GB，以文件夹形式存放在模型目录中，Windows 和 Android 都可以用。

| 模型 | 语言 | 许可证 |
| --- | --- | --- |
| [Nemotron Speech Streaming EN 0.6B](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) | 仅英语 | [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/) |
| [Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) | 35 种语言，自动检测，精度较差 | [OpenMDW 1.1](https://openmdw.ai/license/1-1/) |

文件来自 sherpa-onnx `asr-models` 发布中的 int8 导出（560 ms 分块），从其 Hugging Face 镜像的固定版本下载并做 SHA-256 校验。在声音很小的录音上，Whisper Large v3 Turbo 仍然给出更完整的文稿；英文 Nemotron 模型接近，多语言模型差一些。Nemotron 不需要显卡和 whisper-server，也是 Android 上唯一的本地引擎。

