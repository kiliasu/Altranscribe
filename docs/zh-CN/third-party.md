# 第三方组件与许可

[English](../en/third-party.md) | 简体中文 · [首页](../../README.zh-CN.md)

项目原创代码采用 [MIT 许可证](../../LICENSE)，随包组件继续遵循各自的许可证，许可证文本已包含在安装包中。重新分发时保留原始许可证和版权文件。

## 字体

Roboto Flex 使用 SIL OFL 1.1，Material Symbols Rounded 使用 Apache 2.0。转换后的字体和图标子集属于修改版本；Roboto 和 Noto Sans SC 的许可证也保留在字体目录中。详见 [字体来源记录（英文）](../../assets/fonts/README.md)。

## Silero VAD

随包附带的 Silero 模型用于本地 Whisper 的语音检测，不是转录模型，采用 [MIT 许可证](../../assets/models/Silero-LICENSE.txt)。固定来源与校验值见 [模型来源记录（英文）](../../assets/models/README.md)。

## RNNoise 与 SpeexDSP

RNNoise 用于降噪，SpeexDSP 用于重采样。源码、局部修改及模型校验值见 [原生依赖记录（英文）](../../native/third_party/README.md)。保留 [RNNoise 许可证](../../native/third_party/rnnoise/COPYING)和 [SpeexDSP 许可证](../../native/third_party/speex/COPYING)。

## OpenCC

Android 使用 OpenCC 字典进行简体中文转换，采用 [Apache 2.0 许可证](../../assets/opencc/LICENSE)。详见 [字典来源记录（英文）](../../assets/opencc/README.md)。

## FFmpeg

Android 随包提供 FFmpeg 8.1.2 共享库（LGPL 2.1+），由[官方源码包](https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz)通过 `scripts/build-android-ffmpeg.sh` 构建，不含 GPL、非自由和网络组件。GitHub 上的每个 Android 发布都会附上该源码包和构建脚本；另见[开发说明（英文）](../CONTRIBUTING.md#distribution)。
