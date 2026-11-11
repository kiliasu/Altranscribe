# 云服务验证（2026-10-25）

后续离线审阅发现末句收尾与换线发送竞态，已修复，见 [2026-10-26 审阅记录](REVIEW_2026-10-26.md)。下文是当时的真实服务结果；旧版以五秒静默判定噪声完成的做法已替换为完整等待与未确认提示。本轮修复未重跑付费长时测试。

在本机原生 Swift 实现中使用用户授权的测试凭据实际请求服务。音频来自 whisper.cpp 的公开 `samples/jfk.wav`，直接以 PCM 发送，不播放到扬声器。未读取或上传用户录音。Gemini 推理测试串行执行；测试代码在 Gemini 文本请求之间及实时短测试结束后等待 20 秒。续接时仅同时保留新连接与排空尾句的旧连接，同一采集帧不重复发送。

## 实际结果

| 功能 | 实测模型 | 结果 |
| --- | --- | --- |
| OpenAI 文件转录 | `gpt-transcribe` | 通过，包含完整末句，语言及词汇参数被接受 |
| Gemini 文件转录 | `gemini-3.5-transcribe` | 通过，Files 上传、Interactions 转录、删除临时文件 |
| OpenAI 实时转录 | `gpt-live-transcribe` | 通过，完整原文及服务端完成确认 |
| OpenAI 直接语音翻译 | `gpt-realtime-translate` | 通过，同时返回完整原文与中文译文，正常关闭确认 |
| Gemini 实时转录 | `gemini-3.5-transcribe-live` | 通过，两段语音及中间一次续接均完整 |
| Gemini 直接语音翻译 | `gemini-3.5-live-translate-preview` | 两段原文与中文译文及中间一次续接通过；预览服务未发送最终确认，应用保留结果并提示核对末句 |
| OpenAI 翻译与摘要 | `gpt-6.1-sol` | Responses 实际请求均通过 |
| Anthropic 翻译与摘要 | `claude-sonnet-5-5` | Messages 实际请求均通过 |
| Gemini 翻译与摘要 | `gemini-3.5-flash-lite` | Interactions 实际请求均通过 |
| Gemini 最新默认文本模型 | `gemini-3.8-flash` | 模型列表中可用，但推理遇到 HTTP 503 或 120 秒超时；未通过 |

Gemini 实时转录十分钟边界实测通过：耗时 625 秒，按正式策略在九分钟完成一次续接；第 610 秒后再次发送的语音完整保留，末段时间超过 610 秒，并收到完成确认。直接翻译另用缩短的续接间隔验证，两段语音在切换前后均返回完整原文与中文译文；其最终确认仍受预览服务限制。

Gemini 3.8 Flash 保留为官方当前推荐默认预选；实测可用的 3.5 Flash-Lite 可直接从列表选择。22:56 的最后一次串行复核仍在 120 秒后超时，不能标记为通过。没有在请求失败后偷偷更换模型或自动重复计费请求。现有用户选择保留；切换服务或使用 OpenAI 快捷填入时采用新的默认值。

## 修复与依据

- 参考原 Flutter 的 `lib/data/services/cloud/cloud_live.dart`、`cloud_file_engine.dart` 和 `cloud_provider.dart`，移植专用模型路由、24 kHz / 16 kHz PCM 区别、事件归并、尾句排空及临时文件清理。
- OpenAI Responses 成功响应中的 `error: null` 之前被误判为失败，已修复。官方 OpenAI 使用 Responses，本机及自定义兼容文本服务仍使用 Chat Completions。
- Anthropic 使用独立 Messages 协议、Bearer 认证及 `anthropic-version: 2026-10-21`；Sonnet 5.5 的 thinking 配置按其能力设置，并提供可选工作区 ID。
- Gemini 文本和专用文件转录使用 Interactions。文件上传 URL 限制在官方 HTTPS 主机，失败与取消后也执行删除；清理失败显示提示并保留转录。
- Gemini 实时认证改用官方 SDK 的 `x-goog-api-key` 请求头，避免密钥出现在连接 URL 中。输入、输出转录配置位于 `setup` 根部。
- 独立 Python WebSocket 客户端和原生客户端均复现了 Gemini 自动 VAD 在同一公开语音中提前结束、遗漏后半句；按官方手动 `activityStart/activityEnd` 后，两端都返回完整文本。原生实现已采用该方式。
- OpenAI 实时转录在静音边界或最长 20 秒提交；独立原文/译文事件合并保存，最终结果替换临时文本。直接翻译不再额外调用文本翻译服务。
- Gemini 默认九分钟准备续接，静音处切换，最迟九分三十秒；OpenAI 默认五十五分钟准备续接。暂停时间也计入连接寿命。服务端 `goAway` 可缩短续接截止时间。失败保留已收到的文本。

官方依据：[OpenAI 转录](https://developers.openai.com/api/docs/guides/speech-to-text)、[实时转录](https://developers.openai.com/api/docs/guides/realtime-transcription)、[实时翻译](https://developers.openai.com/api/docs/guides/realtime-translation)、[Gemini 转录](https://ai.google.dev/gemini-api/docs/transcribe)、[实时转录与手动 VAD](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe)、[实时翻译](https://ai.google.dev/gemini-api/docs/live-api/live-translate)、[会话时限](https://ai.google.dev/gemini-api/docs/live-api/session-management)、[Interactions](https://ai.google.dev/gemini-api/docs/interactions-overview)、[Anthropic 认证](https://platform.claude.com/docs/en/manage-claude/authentication)、[API 版本](https://platform.claude.com/docs/en/api/versioning)、[thinking](https://platform.claude.com/docs/en/build-with-claude/thinking)。

## 必要回归与复现

17 项现有或本次必要的检查通过：API 7 项、实时事件协议 2 项、双语资源 1 项、采集分块 3 项、保存与翻译工作流 4 项。不运行模型下载和全套离线引擎测试。

```sh
swift test --package-path apple --filter 'APITests|CloudSpeechTests|LocalizationTests|WorkflowTests|CaptureTests'
```

真实云端测试仅显式启用时运行，不包含密钥或自动付费请求。准备本机权限为 `0600` 的 JSON 文件，字段为 `openai`、`anthropic`、`gemini`，通过 `ALTRANSCRIBE_CLOUD_KEYS` 传入路径；通过 `ALTRANSCRIBE_CLOUD_AUDIO` 指向公开 WAV。

- `testRealFileTranscriptionAndTextServices`：文件转录、文本翻译与摘要。
- `testRealLiveTranscriptionTranslationAndRenewal`：实时转录、双语输出、短时续接及末句。
- `testRealGeminiAcrossTenMinuteBoundary`：额外设置 `ALTRANSCRIBE_CLOUD_LONG=1`，在真实 610 秒后再次发送语音，使用正式九分钟续接策略。

可用 `ALTRANSCRIBE_CLOUD_CASE` 只执行一条路径，例如 `gemini:translate` 或 `anthropic:text`；`ALTRANSCRIBE_CLOUD_TEXT_MODEL` 仅用于指定文本测试模型。普通测试运行会跳过所有真实云端请求。

## 覆盖边界

本轮云端音频测试直接使用原生处理链发送公开音频，没有重新测试真实麦克风、系统录音权限、蓝牙或全部语言。没有执行 OpenAI 六十分钟实测，没有验证全部历史模型及自定义服务。Gemini 翻译预览版的服务端最终确认与 3.8 Flash 的当前推理可用性仍有限制，不能据此宣称全部在线模型均可用。

原生应用中实际点击检查了三个设置标签、服务切换、最新默认模型、实时直接翻译开关、主页模型提示以及文件翻译仍使用文本模型的路径。共用语音密钥位于独立服务区，保留原生圆角分段控件。测试后恢复原设置文件，五份已有记录的 SHA-256 全部未变，未修改钥匙串。

Release 构建及 `codesign --verify --deep --strict` 通过。重新生成 `build/macos/Altranscribe-macOS-arm64.zip`，解压后的 30 个文件逐一与构建目录校验一致；启动解压实例并从进程路径确认，随后返回正式本地构建。压缩包为 17,289,518 字节，不含模型权重。

本地详细日志保存在忽略目录 `.build/cloud-validation-2026-10-25/`，不会提交测试密钥。结束前通过 Files 列表确认 `Altranscribe audio` 临时上传剩余为零；源码、测试、报告及日志的凭据扫描通过，本地临时测试凭据文件已删除。

## 修复后复测（2026-10-25 深夜）

审查当天提交后修复了会话层（见 [验证记录](VALIDATION.md) 的「云端会话稳健性修复与离线回归」），随后用用户另行提供的测试凭据重新执行真实云端测试。音频仍为公开 `jfk.wav`，凭据只放在仓库外权限 `0600` 的临时文件中，通过 `ALTRANSCRIBE_CLOUD_KEYS` 传入，测试后删除；日志不含密钥。

| 用例 | 结果 |
| --- | --- |
| OpenAI 文件转录 `gpt-transcribe` | 通过，末句完整 |
| Gemini 文件转录 `gemini-3.5-transcribe` | 通过，上传、Interactions 转录、删除临时文件 |
| OpenAI `gpt-6.1-sol`、Gemini `gemini-3.5-flash-lite`、Anthropic `claude-sonnet-5-5` 翻译与摘要 | 均通过；Anthropic 个人密钥未填工作区 ID 亦可用 |
| OpenAI 实时转录 / 直接语音翻译 | 通过，服务端确认关闭，中文译文完整 |
| Gemini 实时转录（15 秒缩短续接） | 通过，续接一次，切换前后两段语音完整 |
| Gemini 直接语音翻译（15 秒缩短续接） | 两段原文与中文译文完整；预览服务仍不发送最终确认 |
| Gemini 噪声活动：噪声、语音、噪声后停止 | 首版按完成信号计数的修复失败：服务对纯噪声活动不发送任何事件，停止等到 20 秒超时。改为不计数后通过：停止确认，耗时 24 秒，语音文本完整 |
| Gemini 十分钟边界（正式九分钟续接策略，重写后的续接代码） | 通过，耗时 625 秒，第 551 秒前完成一次续接，第 610 秒后再次发送的语音完整保留并收到完成确认。中间版本（按完成信号计数）曾在停止时超时，最终版本通过 |

噪声用例是本轮新增的真实测试：以均匀分布 ±0.01 的随机样本模拟超过本地有声门限（RMS 0.002）但没有语音的声音。首版修复假设服务端会对每个活动发送完成信号，结果显示 Gemini 对纯噪声活动不发送任何事件，停止等到 20 秒超时；最终实现因此改为不按活动计数，只有噪声的末段按服务端静默约 5 秒判定完成，已返回文本的活动仍等待其完成信号。

未重新执行 OpenAI 六十分钟实测、真实麦克风和全部语言；Gemini 翻译预览版的最终确认限制不变。
