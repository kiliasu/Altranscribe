#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
# Native tools see paths as C:/..., the form that ends up in the libraries.
win_root="$(cygpath -m "$root")"
export TMPDIR="$root/.tools/ffmpeg-android/tmp"
mkdir -p "$TMPDIR"
sdk_root="$(cygpath -m "${ANDROID_HOME:-$root/.tools/android-sdk}")"
toolchain="$sdk_root/ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64"
if [[ ! -f "$toolchain/bin/clang.exe" ]]; then
  echo 'Install Android NDK 28.2.13676358 in the selected Android SDK.' >&2
  exit 1
fi
destination="$root/.tools/ffmpeg-android/arm64-v8a"
mkdir -p "$root/.tools/ffmpeg-android/build-arm64"
cd "$root/.tools/ffmpeg-android/build-arm64"
../ffmpeg-8.1.2/configure \
  --prefix="$destination" --target-os=android --arch=aarch64 \
  --enable-cross-compile --sysroot="$toolchain/sysroot" \
  --cc="$toolchain/bin/clang.exe" --cxx="$toolchain/bin/clang++.exe" \
  --host-cc="$toolchain/bin/clang.exe" --host-ld="$toolchain/bin/clang.exe" \
  --host-cflags='--target=x86_64-pc-windows-msvc' \
  --host-ldflags='--target=x86_64-pc-windows-msvc -fuse-ld=lld' \
  --ld="$toolchain/bin/clang.exe" --ar="$toolchain/bin/llvm-ar.exe" \
  --nm="$toolchain/bin/llvm-nm.exe" --ranlib="$toolchain/bin/llvm-ranlib.exe" \
  --strip="$toolchain/bin/llvm-strip.exe" \
  --extra-cflags="--target=aarch64-linux-android29 -ffile-prefix-map=$win_root/.tools/ffmpeg-android/=" \
  --extra-ldflags='--target=aarch64-linux-android29 -Wl,-z,max-page-size=16384' \
  --disable-autodetect --disable-everything --disable-network \
  --disable-programs --disable-doc --disable-debug --disable-asm \
  --enable-small --enable-pic --enable-shared --disable-static \
  --enable-avcodec --enable-avformat --enable-avutil --enable-swresample \
  --disable-avdevice --disable-avfilter --disable-swscale \
  --enable-demuxer=asf,aac,wav,mp3,mov,matroska,ogg,flac \
  --enable-parser=aac,aac_latm,ac3,flac,mpegaudio,opus,vorbis \
  --enable-decoder='aac*,ac3*,eac3,alac,flac,mp3*,mp2*,opus,vorbis,wma*,pcm*'
# Every library embeds this configure line (avutil_configuration() and friends),
# so keep local folder names out of the shipped APK.
sed -i -e "s|$win_root/||g" -e "s|$root/||g" -e "s|$sdk_root/||g" config.h
"$root/.tools/ffmpeg-android/make/usr/bin/make.exe" -j8
"$root/.tools/ffmpeg-android/make/usr/bin/make.exe" install
