#ifndef ALTRANSCRIBE_AUDIO_PROCESSING_H_
#define ALTRANSCRIBE_AUDIO_PROCESSING_H_

#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <memory>
#include <vector>

struct AudioProcessingOptions {
  bool denoise = false;
  bool auto_gain = false;
};

// One instance per source; filters and gain never share state between devices.
class AudioProcessor {
 public:
  using Frame = std::function<void(const std::vector<int16_t>&, bool)>;
  AudioProcessor(int input_rate, int output_rate, AudioProcessingOptions options,
                 const std::filesystem::path& model);
  ~AudioProcessor();
  void Process(const std::vector<float>& mono, const Frame& output);
  void Finish(const Frame& output);
  void Reset();
  double gain_db() const;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

struct SpeechChunk {
  std::vector<int16_t> pcm;
  int64_t start_ms;
  int64_t end_ms;
  bool partial = false;
  bool continues = false;
};

// Capture-time boundaries, independent of recognition/translation latency.
class SpeechChunker {
 public:
  using Output = std::function<void(SpeechChunk)>;
  explicit SpeechChunker(int sample_rate) : rate_(sample_rate) {}
  void Add(const std::vector<int16_t>& pcm, bool speech, const Output& output);
  void Finish(const Output& output);
  void Reset(int64_t start_ms);
 private:
  void Emit(const Output& output, bool continues = false);
  int rate_;
  int64_t origin_ms_ = 0;
  int64_t position_ = 0;
  int64_t start_ = 0;
  int64_t quiet_ = 0;
  int64_t speech_samples_ = 0;
  int64_t preview_samples_ = 0;
  std::deque<int16_t> pre_roll_;
  std::vector<int16_t> pending_;
};
#endif
