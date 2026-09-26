# Third-party notices

English | [简体中文](../zh-CN/third-party.md) · [Home](../../README.md)

Original project code uses the [MIT License](../../LICENSE). Bundled components retain their own licenses, and their license texts ship inside the app package. Keep the original license and copyright files when redistributing them.

## Fonts

Roboto Flex uses SIL OFL 1.1; Material Symbols Rounded uses Apache 2.0. Converted fonts and icon subsets are modified files. Roboto and Noto Sans SC include their license files alongside the fonts. See the [font source notes](../../assets/fonts/README.md).

## Silero VAD

The bundled Silero model detects speech for local Whisper; it is not a transcription model. It uses the [MIT License](../../assets/models/Silero-LICENSE.txt). The pinned source and checksum are in the [model source notes](../../assets/models/README.md).

## RNNoise and SpeexDSP

RNNoise provides denoising; SpeexDSP provides resampling. Source code, local modifications, and model checksums are documented in the [native dependency notes](../../native/third_party/README.md). Preserve the [RNNoise license](../../native/third_party/rnnoise/COPYING) and [SpeexDSP license](../../native/third_party/speex/COPYING).

## OpenCC

Android uses OpenCC dictionaries for Simplified Chinese conversion under [Apache 2.0](../../assets/opencc/LICENSE). See the [dictionary source notes](../../assets/opencc/README.md).

## FFmpeg

Android bundles FFmpeg 8.1.2 shared libraries under LGPL 2.1+, built from the [official source archive](https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz) with `scripts/build-android-ffmpeg.sh`, without GPL, non-free or network components. Each Android release on GitHub attaches that source archive and the build script; see also [Distribution](../CONTRIBUTING.md#distribution).

## QR pairing

The Windows host draws pairing QR codes with the [qr](https://pub.dev/packages/qr) Dart package (BSD 3-Clause); its license text is included in the app's license list. Android scans them with [ZXing](https://github.com/zxing/zxing) core and Jetpack [CameraX](https://developer.android.com/media/camera/camerax), both under Apache 2.0 with no modifications.

## sherpa-onnx and ONNX Runtime

Nemotron streaming recognition uses [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache 2.0) through its Dart package, which bundles [ONNX Runtime](https://github.com/microsoft/onnxruntime) (MIT). The models themselves are downloaded on request and are not part of the app: the English model under the [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/) and the 3.5 multilingual model under [OpenMDW 1.1](https://openmdw.ai/license/1-1/), as listed in the [model guide](models.md).

