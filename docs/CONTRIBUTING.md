# Contributing

Use Flutter 3.47.3 / Dart 3.13.3 and Visual Studio 2022 or its Build Tools with "Desktop development with C++" and the Windows SDK. Put `flutter/bin` on PATH or place the SDK in `.tools/flutter/`, and run the scripts from the repository root. Keep the checkout path short: plugin sources add about 120 characters to it, and the C++ compiler fails beyond 260.

## Windows

```powershell
./dev.ps1 -Verify
./dev.ps1
./dev.ps1 -Build
./dev.ps1 -Build -Release
```

`-Verify` runs the Dart analyzer, the native audio tests and the Flutter tests, `-Build` makes a debug build, and no switch runs the app. `-Build -Release` writes the release build to `build/windows/x64/runner/Release/`; use the script rather than plain `flutter build`, because it prepares the plugin links that Windows needs without Developer Mode. The GitHub workflow runs `-Verify` and `-Build` on every push to `main`.

The script keeps app data in `.tools/runtime/app-data/` and Whisper models in `models/`. `-WhisperDirectory <path>` points it at a whisper.cpp build, and `scripts/setup-whisper-gpu.ps1` downloads whisper.cpp's CUDA build of `whisper-server.exe`, which `-Gpu` uses. In any run, `ALTRANSCRIBE_DATA_DIR` and `ALTRANSCRIBE_MODELS_DIR` override the data and model folders.

The pinned Flutter CLI truncates analyzer messages for paths with non-ASCII characters, so `-Verify` calls the Dart analyzer from the same SDK directly. Android builds from such paths are untested.

## Android

Android also needs Java 17, Git for Windows (for Bash), Android SDK 36, NDK 28.2.13676358 and CMake 3.22.1.

```powershell
./scripts/setup-android.ps1
./scripts/setup-android-ffmpeg.ps1
./android-dev.ps1 -Build
./android-dev.ps1 -Build -Release
```

Skip the first script if you already have the SDK; note that it accepts the Android SDK licenses on your behalf. The scripts look for the SDK in Flutter's configuration, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `.tools/android-sdk/` and Android Studio's default folder, in that order; FFmpeg and Flutter must use the same SDK. APKs go to `build/app/outputs/flutter-apk/`. The debug APK is debuggable and embeds the Dart sources with their local paths, so only the release APK is for distribution. `-Device <serial>` runs it on a phone and `-Test -Device <serial> -Target integration_test/<test>.dart` runs a device test. Build Windows and Android one after the other, not at the same time.

## Code and tests

| Folder | Contents |
| --- | --- |
| `lib/app/`, `lib/features/` | Configuration, theme, strings, screens and session control |
| `lib/data/`, `lib/shared/` | Models, storage, services, shared widgets and platform bridges |
| `native/` | Audio processing shared by Windows and Android, its dependencies and tests |
| `windows/`, `android/` | Native hosts: audio capture, the caption window, permissions and builds |
| `test/`, `integration_test/` | Unit and interface tests, device tests and live-service checks |

The platform folders contain custom audio, caption and lifecycle code, so don't regenerate them. `captionMain` in `lib/main.dart` is the entry point of the floating caption window on both platforms. After changing `native/`, build both platforms.

Regular checks never download models or call paid APIs. The live checks need real services: `dev.ps1 -Smoke -WhisperDirectory <whisper.cpp folder>` and `-RemoteSmoke` (add `-TranslationModel <Ollama model>` for translation), `-CaptionsSmoke`, and `-CloudSmoke`, which is billed and uses the API keys saved in the app. `flutter test test/models/model_download_test.dart --dart-define=MODEL_DOWNLOAD_SMOKE=true` runs the real model download. The Android device tests in `integration_test/` need fixtures and a Windows host pushed by hand, so treat them as maintainer-only. Tests use synthetic audio only. Never commit recordings, transcripts, API keys, host tokens or signing keys.

Keep `pubspec.lock` committed, and update the [third-party notices](en/third-party.md) when a bundled component changes.

## Distribution

Ship the whole Windows `Release` folder; the target computer needs the Visual C++ x64 runtime. Packages go on GitHub Releases.

Release APKs are signed with your release key when `android/key.properties` exists, with the keys `storeFile` (relative to `android/app`), `storePassword`, `keyAlias` and `keyPassword`. Without that file the build falls back to the debug key, which is fine for testing but not for publishing: users can only update an app with builds signed by the same key. The keystore and `key.properties` are ignored by Git; keep backups of both.

Release builds still record one absolute path: Flutter compiles the generated `.dart_tool/flutter_build/dart_plugin_registrant.dart` into `app.so` / `libapp.so` by its full file path. It is only used in stack traces, but it shows the folder you built in, so build from a neutral location such as `C:\build\Altranscribe` if that matters.

The Android app includes FFmpeg shared libraries under LGPL 2.1+, built without GPL, non-free or network components. When you distribute the APK, include the FFmpeg license and offer the matching source. The pinned version, checksums and build options are in `scripts/setup-android-ffmpeg.ps1` and `scripts/build-android-ffmpeg.sh`. RNNoise and SpeexDSP sources and licenses are in `native/third_party/`. The license texts of everything bundled are packaged as Flutter assets (listed in `pubspec.yaml`), and the Android build adds FFmpeg's; add new ones there when a component is added.

Fonts, the OpenCC dictionaries, the small Silero and RNNoise models and their licenses are committed on purpose, so don't ignore every `*.bin`. Whisper models, `.tools/`, `build/`, `.env` files and credentials stay out of Git.
