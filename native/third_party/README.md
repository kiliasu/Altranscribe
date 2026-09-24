# Native audio dependencies

These sources build locally with MSVC or the Android NDK. No dependency or model is downloaded at app startup.

## RNNoise 0.2

- Upstream: https://github.com/xiph/rnnoise
- Source commit: `904a876dce1f9ab8860c0a5000ed151f9f6eef58` (`v0.2`).
- License: [rnnoise/COPYING](rnnoise/COPYING), also installed with the application.
- Official model: https://media.xiph.org/rnnoise/models/rnnoise_data-0b50c45.tar.gz
- Archive SHA-256: `4ac81c5c0884ec4bd5907026aaae16209b7b76cd9d7f71af582094a2f98f4b43`.
- Bundled `rnnoise-model.bin`: 5,530,816 bytes; SHA-256 `35da861b090c25df53ba7f258b1ea55b1ea36d0c9063d9495bc145ada945c90e`.

Only inference sources are included. The generated `rnnoise_data.c` retains the upstream initializer; weights are stored in the binary instead of 29 MB of C literals. `scripts/rebuild-rnnoise-model.ps1` reproduces the binary using the upstream weight writer, changing its file mode to `wb` for Windows. The library uses baseline SSE2, available on Windows x64.

Local fix in `rnnoise_model_from_buffer`: initialize `model->file` to `NULL`. Version 0.2 otherwise leaves it uninitialized and can crash in `rnnoise_model_free` after processing a memory-backed model. Algorithm and weights are unchanged.

Android ARM64 uses the upstream NEON kernels. A minimal local `os_support.h` supplies the `OPUS_CLEAR` memory helper referenced by the v0.2 vector headers but missing from that archive. The SSE2 build flag remains Windows-only.

## SpeexDSP 1.2.1 resampler

- Upstream: https://github.com/xiph/speexdsp/tree/SpeexDSP-1.2.1
- Only `resample.c`, `arch.h`, and `speex_resampler.h` are used, unmodified.
- License: [speex/COPYING](speex/COPYING), also installed with the application.
- Built with `OUTSIDE_SPEEX`, floating point, and the `altranscribe` symbol prefix.

This replaces linear interpolation with band-limited sample-rate conversion before and after the 48 kHz denoiser. Each source owns separate resampler, denoiser, gain and segmentation state.
