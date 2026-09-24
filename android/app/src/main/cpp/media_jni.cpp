#include <jni.h>
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <memory>
#include <poll.h>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>
}

namespace {
void Check(int code) {
  if (code < 0) {
    char message[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, message, sizeof(message));
    throw std::runtime_error(message);
  }
}

struct Decoder {
  int fd = -1, track = -1;
  AVFormatContext* format = nullptr;
  AVIOContext* io = nullptr;
  AVCodecContext* codec = nullptr;
  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  SwrContext* resampler = nullptr;
  std::vector<uint8_t> pending;
  size_t consumed = 0;
  bool finished = false;
  JNIEnv* env = nullptr;
  jobject owner = nullptr; // Borrowed only during the current JNI call.
  jmethodID cancelled = nullptr;

  ~Decoder() {
    swr_free(&resampler);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&codec);
    avformat_close_input(&format);
    if (io) { av_freep(&io->buffer); avio_context_free(&io); }
    if (fd >= 0) close(fd);
  }
  bool IsCancelled() { return env->CallBooleanMethod(owner, cancelled); }
  static int Read(void* opaque, uint8_t* output, int size) {
    auto& self = *static_cast<Decoder*>(opaque);
    while (!self.IsCancelled()) {
      pollfd descriptor{self.fd, POLLIN, 0};
      const auto ready = poll(&descriptor, 1, 200);
      if (ready < 0 && errno == EINTR) continue;
      if (ready < 0) return AVERROR(errno);
      if (!ready) continue;
      const auto count = read(self.fd, output, size);
      if (count < 0 && errno == EINTR) continue;
      return count < 0 ? AVERROR(errno) : count == 0 ? AVERROR_EOF : count;
    }
    return AVERROR_EXIT;
  }
  static int64_t Seek(void* opaque, int64_t offset, int mode) {
    const auto fd = static_cast<Decoder*>(opaque)->fd;
    if (mode == AVSEEK_SIZE) {
      struct stat info{};
      return fstat(fd, &info) == 0 && S_ISREG(info.st_mode) ? info.st_size : AVERROR(ESPIPE);
    }
    const auto result = lseek(fd, offset, mode & ~AVSEEK_FORCE);
    return result < 0 ? AVERROR(errno) : result;
  }
  void Open(int input) {
    fd = dup(input);
    if (fd < 0) throw std::runtime_error("Cannot open audio document");
    auto* buffer = static_cast<uint8_t*>(av_malloc(32768));
    if (!buffer) throw std::bad_alloc();
    io = avio_alloc_context(buffer, 32768, 0, this, Read, nullptr, Seek);
    if (!io) { av_free(buffer); throw std::bad_alloc(); }
    format = avformat_alloc_context();
    if (!format || !packet || !frame) throw std::bad_alloc();
    format->pb = io;
    format->flags |= AVFMT_FLAG_CUSTOM_IO;
    format->probesize = 1024 * 1024;
    format->max_analyze_duration = 5 * AV_TIME_BASE;
    Check(avformat_open_input(&format, nullptr, nullptr, nullptr));
    Check(avformat_find_stream_info(format, nullptr));
    const AVCodec* decoder = nullptr;
    track = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
    Check(track);
    codec = avcodec_alloc_context3(decoder);
    if (!codec) throw std::bad_alloc();
    Check(avcodec_parameters_to_context(codec, format->streams[track]->codecpar));
    Check(avcodec_open2(codec, decoder, nullptr));
  }
  void Convert(bool drain) {
    if (!resampler) {
      if (drain) return;
      AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
      Check(swr_alloc_set_opts2(&resampler, &mono, AV_SAMPLE_FMT_S16, 16000,
                               &frame->ch_layout, static_cast<AVSampleFormat>(frame->format),
                               frame->sample_rate, 0, nullptr));
      Check(swr_init(resampler));
    }
    const auto capacity = swr_get_out_samples(resampler, drain ? 0 : frame->nb_samples);
    Check(capacity);
    pending.resize(capacity * 2);
    auto* output = pending.data();
    const auto count = swr_convert(resampler, &output, capacity,
        drain ? nullptr : const_cast<const uint8_t**>(frame->extended_data), drain ? 0 : frame->nb_samples);
    Check(count);
    pending.resize(count * 2); consumed = 0;
  }
  std::vector<uint8_t> Next(int limit) {
    std::vector<uint8_t> result;
    result.reserve(limit);
    while (result.size() < static_cast<size_t>(limit) && !IsCancelled()) {
      const auto count = std::min(pending.size() - consumed, limit - result.size());
      result.insert(result.end(), pending.begin() + consumed, pending.begin() + consumed + count);
      consumed += count;
      if (result.size() == static_cast<size_t>(limit) || finished) break;
      pending.clear(); consumed = 0;
      const auto decoded = avcodec_receive_frame(codec, frame);
      if (decoded >= 0) { Convert(false); av_frame_unref(frame); continue; }
      if (decoded == AVERROR_EOF) { Convert(true); finished = true; continue; }
      if (decoded != AVERROR(EAGAIN)) Check(decoded);
      int read;
      do {
        av_packet_unref(packet);
        read = av_read_frame(format, packet);
      } while (read >= 0 && packet->stream_index != track && !IsCancelled());
      if (IsCancelled()) break;
      if (read == AVERROR_EOF) Check(avcodec_send_packet(codec, nullptr));
      else { Check(read); Check(avcodec_send_packet(codec, packet)); }
    }
    return result;
  }
};
void Error(JNIEnv* env, const std::exception& error) {
  env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), error.what());
}
}

extern "C" JNIEXPORT jlong JNICALL
Java_app_altranscribe_NativeFileDecoder_create(JNIEnv* env, jobject owner, jint fd) {
  try {
    av_log_set_level(AV_LOG_QUIET);
    auto decoder = std::make_unique<Decoder>();
    decoder->env = env; decoder->owner = owner;
    decoder->cancelled = env->GetMethodID(env->GetObjectClass(owner), "isCancelled", "()Z");
    decoder->Open(fd);
    return reinterpret_cast<jlong>(decoder.release());
  } catch (const std::exception& error) { Error(env, error); return 0; }
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_app_altranscribe_NativeFileDecoder_read(JNIEnv* env, jobject owner, jlong pointer, jint limit) {
  try {
    if (!pointer || limit < 2 || limit > 19200000) throw std::invalid_argument("Invalid audio window");
    auto& decoder = *reinterpret_cast<Decoder*>(pointer);
    decoder.env = env; decoder.owner = owner;
    const auto pcm = decoder.Next(limit);
    auto result = env->NewByteArray(pcm.size());
    env->SetByteArrayRegion(result, 0, pcm.size(), reinterpret_cast<const jbyte*>(pcm.data()));
    return result;
  } catch (const std::exception& error) { Error(env, error); return nullptr; }
}
extern "C" JNIEXPORT void JNICALL
Java_app_altranscribe_NativeFileDecoder_destroy(JNIEnv*, jobject, jlong pointer) {
  delete reinterpret_cast<Decoder*>(pointer);
}
