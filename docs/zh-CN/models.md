# Whisper 模型

[English](../en/models.md) | 简体中文 · [首页](../../README.zh-CN.md)

Windows 用户可在「设置 → 模型选择」中下载模型。下载完成后选择模型并保存；支持进度显示、取消与重试，重试从头开始。应用关闭后下载会停止。

模型存放在 `%LOCALAPPDATA%\Altranscribe\models\`，也就是模型面板里显示的目录。

## 手动添加

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

应用下载会校验固定版本的文件大小与 SHA-256；手动添加时只检查文件名、大小和文件头。下载模型不包含 Whisper 运行程序，需另行配置 `whisper-server.exe`。Android 使用远程或云端推理，不提供本地下载入口。

随包附带的 [Silero VAD](third-party.md#silero-vad) 会在启动本地 Whisper 时复制到模型目录，用于语音检测，不属于可选转录模型。
