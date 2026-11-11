#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct ALTWhisper ALTWhisper;
typedef void (*ALTSegmentCallback)(int64_t start_ms, int64_t end_ms, const char *text, void *user);
ALTWhisper *alt_whisper_create(const char *model_path, bool gpu);
void alt_whisper_free(ALTWhisper *engine);
void alt_whisper_cancel(ALTWhisper *engine);
void alt_whisper_reset_cancel(ALTWhisper *engine);
int alt_whisper_transcribe(ALTWhisper *engine, const float *samples, int count,
                          const char *language, const char *prompt,
                          ALTSegmentCallback callback, void *user);
#ifdef __cplusplus
}
#endif
