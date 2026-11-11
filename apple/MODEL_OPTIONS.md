# macOS 转写模型备选

调研日期：2026-10-23。当前应用已接入 Nemotron 英语版 / 3.5 多语言版、Whisper，以及新增的 FluidAudio Parakeet v2 / v3 和 Apple SpeechTranscriber。后两者的实际执行结果见 [验证记录](VALIDATION.md)。其余候选仅核对了模型卡和实现文档，尚未集成或实测。

| 方案 | macOS 路线与语言 | 适用场景及接入代价 |
| --- | --- | --- |
| Parakeet TDT 0.6B v2 / v3 | [NVIDIA 模型](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)的 v3 覆盖英语等 25 种欧洲语言，不含中文；[FluidAudio](https://github.com/FluidInference/FluidAudio/tree/v0.17.7) 提供 Swift / Core ML 路线 | 已集成。默认 v2 英语版，可选 v3；设置页下载/删除模型，实时 8 秒、文件 20 秒分块。速度、功耗和准确率没有做系统对照。Ultra 是另一个后训练衍生模型，本次未接入。 |
| Apple SpeechTranscriber | [SpeechAnalyzer / SpeechTranscriber](https://developer.apple.com/videos/play/wwdc2025/277/) 提供系统管理的本机转写，与本应用 macOS 26 最低版本相符 | 已集成。本机系统确认支持英语、中文等语言；配置页实时查询设备可用性、语言列表和安装状态，语言资产由系统管理。当前应用采用分块结果，并在每块结尾完成最终文本。 |
| SenseVoiceSmall | [sherpa-onnx 官方适配](https://k2-fsa.github.io/sherpa/onnx/sense-voice/)支持 macOS arm64 / x64、Swift，以及普通话、粤语、英语、日语、韩语 | 中文扩展成本较低：复用已引入的 sherpa-onnx / ONNX Runtime，补离线识别器与模型目录即可。实时录音需按停顿或 VAD 分段，不能直接当作 Nemotron 的持续流式解码器。 |
| Qwen3-ASR 0.6B / 1.7B | [官方模型卡](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)列出 30 种语言及 22 种中文方言；[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Qwen3ASR/README.md) 提供 Apple Silicon / MLX 实现及量化模型 | 值得评估中英混合与中文文件。需要新增 MLX 运行时及内存管理，成本高于复用 sherpa。文档中的 `generateStream(audio:)` 是对已提供音频逐步输出文本，不等于持续接收麦克风音频的状态式流式识别；精确词级时间戳需额外对齐方案。 |
| Moonshine | [官方 Swift 包](https://github.com/moonshine-ai/moonshine-swift/blob/main/Package.swift)支持 macOS 13+；[官方示例](https://moonshine-voice.readthedocs.io/en/stable/examples/)覆盖文件、实时麦克风和增量结果 | 适合评估轻量英语听写。需要新的运行时和模型下载管理，成本中等；语言覆盖要按具体模型确认，不能将整个系列的语言能力套到每个型号上。 |

## 建议顺序

当前以英语为主，继续保留 Nemotron 默认配置。FluidAudio 与 Apple 已成为可选项；可用实际课程或会议素材比较其识别质量，本次不做扩大范围的性能评测。

若增加中文重点场景，先评估能复用现有运行时的 SenseVoiceSmall，再决定是否值得引入 Qwen3-ASR / MLX。Moonshine 留作轻量实时听写的候选。选择前用同一段实际使用场景的音频比较漏字、专名、尾句和耗时即可，暂不扩大测试矩阵。

现有基线仅为 M3 Pro 上 11 秒公开英语样本：Nemotron 英语版 CPU 解码约 0.97 秒，不含模型加载及等待音频。该结果不能用于推断上述候选的相对速度或准确率；完整条件见 [验证记录](VALIDATION.md)。
