# macOS 转写模型备选

调研日期：2026-10-23。当前应用已接入 Nemotron 英语版 / 3.5 多语言版及 Whisper。下列方案仅核对了模型卡和实现文档，尚未在此应用中集成或实测；接入成本与优先级是基于现有代码的工程判断。

| 方案 | macOS 路线与语言 | 适用场景及接入代价 |
| --- | --- | --- |
| Parakeet TDT 0.6B v3 | [NVIDIA 模型](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)覆盖英语等 25 种欧洲语言，不含中文；[FluidAudio](https://github.com/FluidInference/FluidAudio) 提供 Swift / Core ML 路线 | 优先评估英语文件转写。需要加入 Core ML 模型管理和结果适配，成本中等；实际速度、功耗和准确率需要与现有 Nemotron 对照。FluidAudio 的 [Parakeet Ultra](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md) 是 moondream 后训练衍生模型的 Core ML 版本，不是 NVIDIA 原版的另一个名称。 |
| Apple SpeechTranscriber | [SpeechAnalyzer / SpeechTranscriber](https://developer.apple.com/videos/play/wwdc2025/277/) 提供系统管理的本机转写，支持实时及长音频；与本应用 macOS 26 最低版本相符 | 适合减少第三方引擎和模型维护。模型资产由系统管理，需按设备检查 `isAvailable`、`supportedLocales` 和安装状态；尚未确认本机可用语言及下载状态。 |
| SenseVoiceSmall | [sherpa-onnx 官方适配](https://k2-fsa.github.io/sherpa/onnx/sense-voice/)支持 macOS arm64 / x64、Swift，以及普通话、粤语、英语、日语、韩语 | 中文扩展成本较低：复用已引入的 sherpa-onnx / ONNX Runtime，补离线识别器与模型目录即可。实时录音需按停顿或 VAD 分段，不能直接当作 Nemotron 的持续流式解码器。 |
| Qwen3-ASR 0.6B / 1.7B | [官方模型卡](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)列出 30 种语言及 22 种中文方言；[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Qwen3ASR/README.md) 提供 Apple Silicon / MLX 实现及量化模型 | 值得评估中英混合与中文文件。需要新增 MLX 运行时及内存管理，成本高于复用 sherpa。文档中的 `generateStream(audio:)` 是对已提供音频逐步输出文本，不等于持续接收麦克风音频的状态式流式识别；精确词级时间戳需额外对齐方案。 |
| Moonshine | [官方 Swift 包](https://github.com/moonshine-ai/moonshine-swift/blob/main/Package.swift)支持 macOS 13+；[官方示例](https://moonshine-voice.readthedocs.io/en/stable/examples/)覆盖文件、实时麦克风和增量结果 | 适合评估轻量英语听写。需要新的运行时和模型下载管理，成本中等；语言覆盖要按具体模型确认，不能将整个系列的语言能力套到每个型号上。 |

## 建议顺序

当前以英语为主，先保留已验证的 Nemotron 默认配置。如果下一步需要改善英语文件转写或探索 Neural Engine 路线，优先对照 Parakeet / FluidAudio；如果更重视系统集成与减少自带依赖，先试 Apple SpeechTranscriber。

若增加中文重点场景，先评估能复用现有运行时的 SenseVoiceSmall，再决定是否值得引入 Qwen3-ASR / MLX。Moonshine 留作轻量实时听写的候选。选择前用同一段实际使用场景的音频比较漏字、专名、尾句和耗时即可，暂不扩大测试矩阵。

现有基线仅为 M3 Pro 上 11 秒公开英语样本：Nemotron 英语版 CPU 解码约 0.97 秒，不含模型加载及等待音频。该结果不能用于推断上述候选的相对速度或准确率；完整条件见 [验证记录](VALIDATION.md)。
