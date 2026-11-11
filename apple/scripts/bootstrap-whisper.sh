#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REVISION=231638a0717b7822784297e5980965ffcec05810
SOURCE="$ROOT/.build/whisper-src"
BUILD="$ROOT/.build/whisper-build"
OUTPUT="$ROOT/.build/native"
command -v cmake >/dev/null || { echo 'Install CMake first: brew install cmake' >&2; exit 1; }
if [ ! -d "$SOURCE/.git" ]; then
    git clone https://github.com/ggml-org/whisper.cpp.git "$SOURCE"
fi
if [ "$(git -C "$SOURCE" rev-parse HEAD)" != "$REVISION" ]; then
    git -C "$SOURCE" fetch origin "$REVISION"
    git -C "$SOURCE" checkout --detach "$REVISION"
fi
cmake -S "$SOURCE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF
cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.logicalcpu)"
mkdir -p "$OUTPUT"
find "$BUILD" -name '*.a' -print0 | xargs -0 libtool -static -o "$OUTPUT/libAltranscribeWhisper.a"
cp "$SOURCE/LICENSE" "$OUTPUT/whisper-LICENSE"
printf '%s\n' "$REVISION" > "$OUTPUT/revision"
