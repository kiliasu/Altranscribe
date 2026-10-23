# Altranscribe for macOS

基于 `origin/dev` 的 `e90c412`，独立实现的原生 macOS 应用。界面使用 SwiftUI / AppKit，音频使用 AVFoundation / ScreenCaptureKit。本地支持 Nemotron 流式识别（sherpa-onnx / CPU）和 Whisper（whisper.cpp / Metal），直接运行在应用进程中。不包含 Flutter、WebView 或本地 HTTP 推理服务器。

最低系统 macOS 26；本机使用 Xcode 27、Swift 6.4、macOS 27.0.1 / Apple Silicon 开发。应用的侧栏、工具栏、表单、菜单、对话框、文件选择器和外观跟随系统设计，字幕窗口使用系统 Liquid Glass。Intel Mac 未验证。

## 本地构建

需要 Xcode 26 或更新版本、CMake（`brew install cmake`）。所有命令在仓库根目录运行：

```sh
bash macos/scripts/bootstrap-whisper.sh
bash macos/scripts/build-app.sh
open build/macos/Altranscribe.app
```

首次会从 whisper.cpp 官方仓库下载固定提交的源代码。Swift Package Manager 下载并校验固定的 sherpa-onnx 1.13.8 和 ONNX Runtime 1.28.1 macOS 静态 XCFramework。构建缓存均放在被 Git 忽略的 `.build` 目录中；依赖齐全后可以离线构建。应用位于 `build/macos/Altranscribe.app`，采用本地 ad-hoc 签名，没有发布、公证或上传。可直接将 `.app` 拖入「应用程序」。

可以用 Xcode 打开 `macos/Package.swift` 阅读、编辑和调试。测试可通过 Swift Package 运行；麦克风和系统声音的实际使用请启动打包后的 `.app`，保证权限说明和应用身份完整。

默认包只含引擎，在设置中下载模型即可使用。也可以为本地交付内置 Tiny 多语言模型，构建时会校验其 SHA-256：

```sh
ALTRANSCRIBE_BUNDLE_TINY=/absolute/path/ggml-tiny.bin bash macos/scripts/build-app.sh
```

内置模型随 `.app` 移动，无需设置绝对路径。Tiny 用于快速体验，准确度要求较高时建议在设置中下载 Small 或 Large v3 Turbo。

## 保留的功能

| 功能 | macOS 实现 |
| --- | --- |
| 本地语音识别 | 默认 Nemotron 英语版，CPU / INT8；可选 Nemotron 3.5 多语言版或 Whisper / Metal；每次任务只加载一次模型 |
| 模型管理 | 两种 Nemotron、Tiny、Base、Small、Large v3 Turbo 下载、校验、删除；Whisper 可选择已有 GGML 文件 |
| 麦克风 | AVAudioEngine；使用 macOS 当前默认输入设备 |
| 系统声音 | ScreenCaptureKit；只读取音频，不保存画面，排除本应用的声音 |
| 实时转写 | Nemotron 持续流式更新，保留上下文，停顿后定稿；Whisper / API 约 8 秒分段；暂停、继续、停止并保存、丢弃 |
| 文件队列 | 原生文件选择与拖放，依次处理，20 秒分块增量解码，停止时保留部分记录 |
| 语音 API | OpenAI / OpenAI-compatible `audio/transcriptions`、Gemini `generateContent` 音频输入 |
| 翻译和摘要 | 本机 Ollama 的 OpenAI 兼容接口、在线兼容服务、OpenAI、Gemini、Anthropic |
| 双语悬浮字幕 | 可移动、可调整大小的原生 NSPanel，字号和只显示翻译选项 |
| 记录库 | 搜索原文/翻译/摘要、复制、重命名、删除、在访达中显示源文件 |
| 导出 | TXT、Markdown、独立 HTML；HTML 内容转义，不执行转写文本 |
| 本地持久化 | 每段转写后原子保存，重启后未完成记录标记为已中断 |
| 外观与语言 | 跟随系统 / 浅色 / 深色；跟随系统 / 简体中文 / English；持久保存偏好 |

## 使用

1. 打开设置（⌘,）→ 语音模型。新安装默认采用 **Nemotron 英语版**；下载约 662 MB 的模型后可离线使用。中文等语言可选约 682 MB 的 Nemotron 3.5 多语言版。也可选择 Whisper 或 API。升级保留原有引擎选择，切换到 Nemotron 时默认使用英语版。
2. 实时转写选择麦克风或系统声音，首次开始时由 macOS 请求相应权限。系统声音需要「隐私与安全性 → 屏幕与系统音频录制」权限；授权后如无法捕获，请退出应用再打开。
3. 文件转写使用 ⌘O 或拖入媒体文件。支持 macOS 可解码的 WAV、M4A、MP3、AAC、AIFF、MP4、MOV 等；实际支持取决于文件编码。MKV、WebM、OGG、WMA 等可能需要先转换。
4. 翻译/摘要默认关闭。开启前在设置中配置文本模型。Ollama 默认地址是 `http://127.0.0.1:11434/v1`；应填写已安装的模型名称或获取模型列表。
5. 「停止并保存」会等待最后一段语音与文本处理完成。「停止处理」立即取消剩余任务并保留已保存文本。已完成记录可在右上角菜单导出或重新翻译/生成摘要。

Nemotron 英语版固定识别英语；多语言版使用右侧的语言选择。模型使用 dev 分支相同的固定 ONNX 导出和 SHA-256 值，四个文件全部校验后才安装，取消或失败不激活不完整模型。实时采集每 320 ms 送入一次音频，模型采用 560 ms 分块；这两个数字均不是最终字幕延迟。临时文本原位更新并保存，定稿后才送入可选翻译服务，停止和文件结尾会排空模型尾段。Nemotron 暂不提供词汇提示或 GPU 加速。

实时翻译单独排队，不阻塞语音识别；积压超过 8 个待处理片段时，保留原文并标明可稍后补译。「停止并保存」会等待已排队翻译，取消处理则保留已保存结果。悬浮字幕保留最近完成的译文，落后于当前原文时显示对应时间。记录库重新翻译按记录的源语言处理，全部成功后一次替换译文；失败或取消保留原记录，并提供进度及取消按钮。

界面支持与原项目一致的简体中文和英语，在设置 → 通用 → 语言切换；另保留 macOS 版的「跟随系统」，系统偏好中没有支持的语言时使用英语。主窗口、设置、悬浮字幕、自定义菜单、状态和应用错误立即切换；macOS 标准菜单与系统对话框在重新打开应用后更新。语言偏好保存在应用自己的 UserDefaults 中。

标题和摘要使用任务开始时的界面语言，与语音识别和翻译目标语言独立，和原项目行为一致。导出中的说明文字，以及界面日期和文件大小按界面语言显示；已有原文、译文、摘要和用户命名保持原样。应用文案集中在 `Sources/AltranscribeCore/Resources/{en,zh-Hans}.lproj/Localizable.strings`，权限说明位于 `Resources/{en,zh-Hans}.lproj/InfoPlist.strings`，构建脚本会将资源一起打包。

其他可适配 macOS 的转写模型及接入取舍见 [模型备选调研](MODEL_OPTIONS.md)。

语音 API 使用分段请求，不接入原项目的云端实时 WebSocket、直接翻译或语音回复。API 转写时间戳标为约值。API 名称可编辑，实际可用性取决于账户权限。付费推理失败不自动重试。

快捷键：导入 ⌘O；开始 ⇧⌘R；暂停/继续 ⇧⌘P；停止保存 ⇧⌘S；悬浮字幕 ⇧⌘C。

## 舍弃的范围与限制

- 不迁移远程主机、共享、配对、二维码、局域网发现及 Windows / Android 平台代码。
- 本版不引入 RNNoise、FFmpeg。
- 一次选择一个实时音源，不同时混合麦克风和系统声音。输入设备在 macOS 系统设置中选择。
- 不迁移自动术语纠错、整份文稿修订对照和 HTML 媒体播放器；保留词汇提示和双语文本导出。
- 不承诺原 Flutter 记录目录格式兼容；原项目文件不修改，macOS 使用独立数据目录。
- 长时间采集如果推理速度落后超过有界队列容量，会明确报错并保留已完成文本，避免无限占用内存。
- 未做说话人分离。模型结果应人工校对；短分段边界可能切开语句。

## 数据与安全

数据位于 `~/Library/Application Support/Altranscribe/`：`Records/` 保存 JSON 文稿，`Models/` 保存下载模型，`settings.json` 保存不含密钥的设置。API 密钥只保存在 macOS Keychain，并按完整 API 基地址隔离。

macOS 记录格式版本 2 保存可随界面语言切换的应用错误及摘要语言；仍可读取版本 1 记录和旧字符串错误。旧记录只在用户后续保存时升级。

实时音频不落盘，不启动监听端口。使用 Nemotron / Whisper 和本机文本服务时，不向在线推理服务发送内容。下载模型与显式选择在线 API 需要网络。在线 API 只允许 HTTPS；明文 HTTP 限定 `localhost`、`127.0.0.1` 和 `::1`。携带密钥的请求不跟随重定向；错误中不显示服务响应正文。

## 验证

i18n 仅新增 2 项测试：双语资源完整性、格式占位符、旧记录兼容和导出；摘要语言不受翻译目标语言影响。复用 3 项工作流回归，共 5 项：

```sh
swift test --package-path macos --filter 'LocalizationTests|testSummaryUsesCapturedInterfaceLanguageInsteadOfTranslationTarget|WorkflowTests'
```

细节修复仅新增 3 项回归测试，覆盖慢翻译与有界队列、补标点保留译文、源语言、重新翻译失败/取消及设置损坏时的记录恢复：

```sh
swift test --package-path macos --filter WorkflowTests
```

Nemotron 接入仅新增两项测试：英语默认值与旧设置兼容；真实模型的流式结果、尾句、文件队列和保存。使用公开 JFK 样本，模型不存在时会下载到指定的本地验证目录：

```sh
ALTRANSCRIBE_TEST_NEMOTRON_ROOT="$PWD/.build/nemotron-validation" \
ALTRANSCRIBE_TEST_AUDIO="$PWD/.build/whisper-src/samples/jfk.wav" \
ALTRANSCRIBE_TEST_MULTILINGUAL=1 \
swift test --package-path macos --filter NemotronTests
```

以下为原有迁移测试，按需运行；本次 Nemotron 接入不重复运行整套测试：

```sh
swift test --package-path macos

# 包含真实 Metal 推理的集成验证，使用 whisper.cpp 随附的 JFK 测试音频：
ALTRANSCRIBE_TEST_MODEL=/absolute/path/ggml-tiny.bin \
ALTRANSCRIBE_TEST_AUDIO="$PWD/.build/whisper-src/samples/jfk.wav" \
swift test --package-path macos
```

测试覆盖端点边界、认证请求、API 结果和错误处理、实时音频重采样、暂停/停止尾段保留、采集队列过载、存储恢复、搜索、HTML 转义、增量媒体解码、延迟音轨对齐与真实 Whisper 推理。没有 API 凭证时使用协议替身验证接口，不进行付费调用。本机已完成静音条件下的实际系统音频转写、暂停/恢复和保存，以及真实麦克风的启动、暂停和停止；麦克风真人语音识别按用户要求留待稍后。此次本地结果见 [验证记录](VALIDATION.md)。

设计与接口依据：[Apple SwiftUI 新设计](https://developer.apple.com/videos/play/wwdc2025/323/)、[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)、[whisper.cpp](https://github.com/ggml-org/whisper.cpp)、[Nemotron / sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/nemo/nemotron-streaming.html)、[OpenAI 音频 API](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)、[Gemini 音频](https://ai.google.dev/gemini-api/docs/audio)、[Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create)。应用内附带 Whisper、sherpa-onnx、ONNX Runtime 的许可证及 ONNX Runtime 第三方声明；模型许可见设置中的对应模型卡。
