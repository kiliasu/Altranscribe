#include <jni.h>
#include "audio_processing.h"
#include <string>

namespace {
void Error(JNIEnv* env, const std::exception& error) {
  env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), error.what());
}
AudioProcessor::Frame Callback(JNIEnv* env, jobject target) {
  const auto method = env->GetMethodID(env->GetObjectClass(target), "onFrame", "([BZ)V");
  return [env, target, method](const std::vector<int16_t>& pcm, bool speech) {
    auto bytes = env->NewByteArray(pcm.size() * 2);
    env->SetByteArrayRegion(bytes, 0, pcm.size() * 2,
                           reinterpret_cast<const jbyte*>(pcm.data()));
    env->CallVoidMethod(target, method, bytes, static_cast<jboolean>(speech));
    env->DeleteLocalRef(bytes);
  };
}
}

extern "C" JNIEXPORT jlong JNICALL
Java_app_altranscribe_NativeDsp_create(JNIEnv* env, jobject, jint input, jint output,
                                     jboolean denoise, jboolean gain, jstring path) {
  const char* utf = env->GetStringUTFChars(path, nullptr);
  const std::string model(utf);
  env->ReleaseStringUTFChars(path, utf);
  try {
    return reinterpret_cast<jlong>(new AudioProcessor(input, output, {bool(denoise), bool(gain)}, model));
  } catch (const std::exception& e) { Error(env, e); return 0; }
}
extern "C" JNIEXPORT void JNICALL
Java_app_altranscribe_NativeDsp_process(JNIEnv* env, jobject target, jlong pointer,
                                      jfloatArray input) {
  try {
    std::vector<float> samples(env->GetArrayLength(input));
    env->GetFloatArrayRegion(input, 0, samples.size(), samples.data());
    reinterpret_cast<AudioProcessor*>(pointer)->Process(samples, Callback(env, target));
  } catch (const std::exception& e) { Error(env, e); }
}
extern "C" JNIEXPORT void JNICALL
Java_app_altranscribe_NativeDsp_finish(JNIEnv* env, jobject target, jlong pointer) {
  try { reinterpret_cast<AudioProcessor*>(pointer)->Finish(Callback(env, target)); }
  catch (const std::exception& e) { Error(env, e); }
}
extern "C" JNIEXPORT void JNICALL
Java_app_altranscribe_NativeDsp_reset(JNIEnv* env, jobject, jlong pointer) {
  try { reinterpret_cast<AudioProcessor*>(pointer)->Reset(); }
  catch (const std::exception& e) { Error(env, e); }
}
extern "C" JNIEXPORT void JNICALL
Java_app_altranscribe_NativeDsp_destroy(JNIEnv*, jobject, jlong pointer) {
  delete reinterpret_cast<AudioProcessor*>(pointer);
}

// The same capture-time segmentation as Windows, including replaceable previews.
extern "C" JNIEXPORT jlong JNICALL
Java_app_altranscribe_NativeChunker_create(JNIEnv*, jobject, jint rate) {
  return reinterpret_cast<jlong>(new SpeechChunker(rate));
}
namespace {
SpeechChunker::Output Chunks(JNIEnv* env, jobject target) {
  const auto method = env->GetMethodID(env->GetObjectClass(target), "onChunk", "([BJJZZ)V");
  return [env, target, method](SpeechChunk chunk) {
    auto bytes = env->NewByteArray(chunk.pcm.size() * 2);
    env->SetByteArrayRegion(bytes, 0, chunk.pcm.size() * 2,
                           reinterpret_cast<const jbyte*>(chunk.pcm.data()));
    env->CallVoidMethod(target, method, bytes, static_cast<jlong>(chunk.start_ms),
                       static_cast<jlong>(chunk.end_ms), static_cast<jboolean>(chunk.partial),
                       static_cast<jboolean>(chunk.continues));
    env->DeleteLocalRef(bytes);
  };
}
}
extern "C" JNIEXPORT void JNICALL
Java_app_altranscribe_NativeChunker_add(JNIEnv* env, jobject target, jlong pointer,
                                      jbyteArray input, jboolean speech) {
  std::vector<int16_t> pcm(env->GetArrayLength(input) / 2);
  env->GetByteArrayRegion(input, 0, pcm.size() * 2, reinterpret_cast<jbyte*>(pcm.data()));
  reinterpret_cast<SpeechChunker*>(pointer)->Add(pcm, speech, Chunks(env, target));
}
extern "C" JNIEXPORT void JNICALL
Java_app_altranscribe_NativeChunker_finish(JNIEnv* env, jobject target, jlong pointer) {
  reinterpret_cast<SpeechChunker*>(pointer)->Finish(Chunks(env, target));
}
extern "C" JNIEXPORT void JNICALL
Java_app_altranscribe_NativeChunker_reset(JNIEnv*, jobject, jlong pointer, jlong start) {
  reinterpret_cast<SpeechChunker*>(pointer)->Reset(start);
}
extern "C" JNIEXPORT void JNICALL
Java_app_altranscribe_NativeChunker_destroy(JNIEnv*, jobject, jlong pointer) {
  delete reinterpret_cast<SpeechChunker*>(pointer);
}
