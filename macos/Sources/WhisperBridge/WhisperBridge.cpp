#include "WhisperBridge.h"
#include "whisper.h"
#include <algorithm>
#include <atomic>
#include <thread>

struct ALTWhisper {
    whisper_context *context;
    std::atomic<bool> cancelled{false};
};

ALTWhisper *alt_whisper_create(const char *model_path, bool gpu) {
    auto params = whisper_context_default_params();
    params.use_gpu = gpu;
    params.flash_attn = gpu;
    auto context = whisper_init_from_file_with_params(model_path, params);
    if (!context) return nullptr;
    return new ALTWhisper{context};
}

void alt_whisper_free(ALTWhisper *engine) {
    if (!engine) return;
    whisper_free(engine->context);
    delete engine;
}

void alt_whisper_cancel(ALTWhisper *engine) { engine->cancelled.store(true); }
void alt_whisper_reset_cancel(ALTWhisper *engine) { engine->cancelled.store(false); }

int alt_whisper_transcribe(ALTWhisper *engine, const float *samples, int count,
                          const char *language, const char *prompt,
                          ALTSegmentCallback callback, void *user) {
    auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = std::max(1u, std::min(8u, std::thread::hardware_concurrency()));
    params.language = language;
    params.initial_prompt = prompt;
    params.no_context = true;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.suppress_blank = true;
    params.suppress_nst = true;
    params.abort_callback = [](void *data) {
        return static_cast<ALTWhisper *>(data)->cancelled.load();
    };
    params.abort_callback_user_data = engine;
    int result = whisper_full(engine->context, params, samples, count);
    if (result != 0 || engine->cancelled.load()) return -1;
    for (int i = 0; i < whisper_full_n_segments(engine->context); ++i) {
        if (whisper_full_get_segment_no_speech_prob(engine->context, i) > 0.6f) continue;
        callback(whisper_full_get_segment_t0(engine->context, i) * 10,
                 whisper_full_get_segment_t1(engine->context, i) * 10,
                 whisper_full_get_segment_text(engine->context, i), user);
    }
    return 0;
}
