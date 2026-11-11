# 转录模型

[English](../en/models.md) | 简体中文 · [首页](../../README.zh-CN.md)

在「设置 → 模型选择」中下载模型，完成后选择并保存。下载进度也会显示在转录页，关闭面板后仍会继续；Android 上会在后台继续并显示通知。连接中断会从断点续传，应用关闭后再次下载也会接着下；取消会删除已下载的部分。模型旁的删除按钮可以移除已下载的文件。

Windows 上的模型存放在 `%LOCALAPPDATA%\Altranscribe\models\`，也就是模型面板里显示的目录。

## 运行程序

在 Windows 上，Whisper 和 Nemotron 3.5 Transcribe 的模型各由一个程序加载。程序列在各自的模型下方，下载、取消和移除的方式与模型相同：

| 引擎 | 程序 | 运行于 | 大小（约） |
| --- | --- | --- | ---: |
| Whisper | [whisper.cpp 1.9.4](https://github.com/ggml-org/whisper.cpp/releases/tag/b5130) | NVIDIA GPU | 675 MB |
| Whisper | [whisper.cpp 1.9.4](https://github.com/ggml-org/whisper.cpp/releases/tag/b5130) | CPU | 9 MB |
| Transcribe | [NeMo-Speech.cpp 0.3.0](https://github.com/NVIDIA/NeMo-Speech.cpp/releases/tag/v0.3.0) | NVIDIA GPU | 509 MB |

文件直接来自各项目的 GitHub 发布页，按固定的大小和 SHA-256 校验后，解压到 `%LOCALAPPDATA%\Altranscribe\programs\`。NVIDIA GPU 版自带 CUDA 运行库，只需要显卡驱动。引擎还没有程序时，下载完成即开始使用；要用自己编译或安装的版本，选择「自定义路径」并填写 `whisper-server.exe` 或 `nemo-speech.exe` 的位置。

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

应用下载会校验固定版本的文件大小与 SHA-256；手动添加时只检查文件名、大小和文件头。模型文件不含运行程序，程序见上文[运行程序](#运行程序)。Whisper 只在 Windows 上运行；Android 可以用 Nemotron、Windows 主机或云端服务。

随包附带的 [Silero VAD](third-party.md#silero-vad) 会在启动本地 Whisper 时复制到模型目录，用于语音检测，不属于可选转录模型。应用自己也会用它在停顿处切分文件：Whisper 一次只听 30 秒，所以每段都在此前最后一个停顿处结束。远处录制的讲座这类远低于正常音量的声音，会先提高音量再交给 Whisper；它的语音检测为了不把提示音当成语音设得较严，否则会把这类语音几乎全部丢掉。

## Nemotron 流式模型

除 Whisper 外，同一面板还提供两个 NVIDIA Nemotron 流式模型，通过 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 在 CPU 上运行。它们随音频到达即时解码，实时字幕约一秒内出现且不会闪动；安静或较远的声音会先自动增益再识别。每个模型约 0.7 GB，以文件夹形式存放在模型目录中，Windows 和 Android 都可以用。

| 模型 | 语言 | 许可证 |
| --- | --- | --- |
| [Nemotron Speech Streaming EN 0.6B](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) | 仅英语 | [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/) |
| [Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) | 35 种语言，自动检测，精度较差 | [OpenMDW 1.1](https://openmdw.ai/license/1-1/) |

文件来自 sherpa-onnx `asr-models` 发布中的 int8 导出（560 ms 分块），从其 Hugging Face 镜像的固定版本下载并做 SHA-256 校验。在声音很小的录音上，Whisper Large v3 Turbo 仍然给出更完整的文稿；英文 Nemotron 模型接近，多语言模型差一些。Nemotron 不需要显卡和 whisper-server，也是 Android 上唯一的本地引擎。

## Nemotron 3.5 Transcribe

[Nemotron 3.5 Transcribe](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B) 是 NVIDIA 用于整段录音的语音大模型，参数 30B，推理时约激活 4B。它自己写出标点，并给出每个词的时间。英文最准；中文属于 NVIDIA 最低的质量档，建议用自己的录音和 Whisper 对比。

它在 Windows 上通过 NVIDIA 的本地运行时 [NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp) 运行，在「Transcribe 程序」中下载。已经用它的 Windows 安装脚本装好的，默认位置会自动找到。

模型是 NVFP4 版本，共约 21.3 GB，分两个文件：解码器和它指定的语音编码器。NVIDIA 没有发布 GGUF 文件（它自己的 NVFP4 权重只能在 Linux 上用 vLLM 运行），所以应用下载的是 [AtomicChat 的转换版本](https://huggingface.co/AtomicChat/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-GGUF)，用 NVIDIA 的转换工具制作，从固定版本下载并做 SHA-256 校验。许可证：[OpenMDW 1.1](https://openmdw.ai/license/1-1/)。

NVFP4 需要 Blackwell 显卡，转录长录音时模型约占 29 GB 显存，实际需要 RTX 5090 这类 32 GB 的显卡；应用启动前会检查，显存被本机 LLM 等占用时会提示。在 RTX 5090 上，模型 20 秒内加载完，58 分钟的讲座约 35 秒转完。文件会在停顿处切成最长 55 分钟的片段，每行保留自己那几个词的时间。本机文字模型和 Transcribe 无法同时放进显存，所以两者轮流使用。所选文件会先全部转录完，等 Transcribe 离开显卡后，再加载用于整理、翻译和摘要的文字模型；已经加载的本机模型会在 Transcribe 启动前卸载。实时转录时，Transcribe 按和 Whisper 相同的短窗口识别；本机文字模型在停止转录后再翻译并生成摘要，要边说边译，请在「设置 → 翻译选择」中改用云端模型。也可以在 Transcribe 的模型设置里让本机模型与它同时运行，这时 Transcribe 先加载，开始页会显示预计显存，可能不足时给出提示。Transcribe 不能在 Android 上运行。
