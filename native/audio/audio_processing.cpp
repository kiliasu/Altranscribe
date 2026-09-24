#include "audio_processing.h"

#include <rnnoise.h>
#include <speex_resampler.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <iterator>
#include <stdexcept>

namespace {
constexpr int kProcessingRate = 48000;
constexpr int kFrame = 480;
using Resampler = std::unique_ptr<SpeexResamplerState, decltype(&speex_resampler_destroy)>;

Resampler MakeResampler(int from, int to) {
  int error = 0;
  Resampler result(speex_resampler_init(1, from, to, 5, &error), speex_resampler_destroy);
  if (!result || error) throw std::runtime_error("Cannot initialize audio resampling");
  return result;
}

std::vector<float> Resample(SpeexResamplerState* state, const float* input, size_t count) {
  std::vector<float> result;
  while (count > 0) {
    std::array<float, 4096> buffer{};
    spx_uint32_t used = static_cast<spx_uint32_t>(count);
    spx_uint32_t size = static_cast<spx_uint32_t>(buffer.size());
    if (speex_resampler_process_float(state, 0, input, &used, buffer.data(), &size)) {
      throw std::runtime_error("Audio resampling failed");
    }
    result.insert(result.end(), buffer.begin(), buffer.begin() + size);
    input += used;
    count -= used;
  }
  return result;
}
}

struct AudioProcessor::Impl {
  int input_rate;
  int output_rate;
  AudioProcessingOptions options;
  std::vector<char> weights;
  std::unique_ptr<RNNModel, decltype(&rnnoise_model_free)> model{nullptr, rnnoise_model_free};
  std::unique_ptr<DenoiseState, decltype(&rnnoise_destroy)> denoiser{nullptr, rnnoise_destroy};
  Resampler up{nullptr, speex_resampler_destroy};
  Resampler down{nullptr, speex_resampler_destroy};
  std::vector<float> pending;
  std::array<std::array<float, kFrame>, 2> dry_delay{};
  size_t dry_index = 0;
  int64_t input_samples = 0;
  int64_t emitted = 0;
  int trim = 0;
  double gain = 0;
  double limiter = 1;
  double speech_rms = .08;
  double noise_rms = .0005;
  int silent_frames = 0;
  bool finishing = false;

  Impl(int from, int to, AudioProcessingOptions settings, const std::filesystem::path& path)
      : input_rate(from), output_rate(to), options(settings) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("Missing bundled RNNoise model");
    weights.assign(std::istreambuf_iterator<char>(file), {});
    model.reset(rnnoise_model_from_buffer(weights.data(), static_cast<int>(weights.size())));
    if (!model) throw std::runtime_error("Invalid bundled RNNoise model");
    Reset();
  }

  void Reset() {
    denoiser.reset(rnnoise_create(model.get()));
    if (!denoiser) throw std::runtime_error("Cannot initialize RNNoise");
    up = MakeResampler(input_rate, kProcessingRate);
    down = MakeResampler(kProcessingRate, output_rate);
    // RNNoise's analysis window and delayed spectrum total two 10 ms frames.
    trim = (speex_resampler_get_output_latency(up.get()) + 2 * kFrame) * output_rate /
               kProcessingRate + speex_resampler_get_output_latency(down.get());
    pending.clear();
    dry_delay = {};
    dry_index = 0;
    input_samples = emitted = 0;
    gain = 0;
    limiter = 1;
    speech_rms = .08;
    noise_rms = .0005;
    silent_frames = 0;
    finishing = false;
  }

  void Feed(const std::vector<float>& mono, const Frame& output) {
    auto converted = Resample(up.get(), mono.data(), mono.size());
    pending.insert(pending.end(), converted.begin(), converted.end());
    size_t offset = 0;
    while (pending.size() - offset >= kFrame) {
      std::array<float, kFrame> input{}, wet{}, enhanced{};
      double raw_energy = 0;
      for (int i = 0; i < kFrame; ++i) {
        const float value = pending[offset + i];
        input[i] = value * 32768.f;
        raw_energy += value * value;
      }
      const float probability = rnnoise_process_frame(denoiser.get(), wet.data(), input.data());
      const double raw_rms = std::sqrt(raw_energy / kFrame);
      if (probability < .2f) noise_rms += .02 * (raw_rms - noise_rms);
      // Energy fallback protects quiet consonants/short words. Final Whisper VAD
      // remains responsible for rejecting non-speech such as notification sounds.
      const bool speech = raw_rms > .0001 &&
          (probability >= .35f || raw_rms > std::max(.003, noise_rms * 3));
      double energy = 0, peak = 0;
      for (int i = 0; i < kFrame; ++i) {
        const float dry = dry_delay[dry_index][i];
        enhanced[i] = options.denoise ? .85f * wet[i] / 32768.f + .15f * dry : dry;
        dry_delay[dry_index][i] = input[i] / 32768.f;
        energy += enhanced[i] * enhanced[i];
        peak = std::max(peak, std::abs(static_cast<double>(enhanced[i])));
      }
      dry_index = (dry_index + 1) % dry_delay.size();
      const double rms = std::sqrt(energy / kFrame);
      const double old_gain = gain;
      if (options.auto_gain) {
        if (probability >= .6f && rms > .0005) {
          silent_frames = 0;
          speech_rms += .1 * (rms - speech_rms);
          const double target = std::clamp(20 * std::log10(.08 / speech_rms), -12.0, 12.0);
          gain += std::clamp(target - gain, -.12, .03);
        } else if (++silent_frames >= 30) {
          gain += std::clamp(-gain, -.06, .06);
        }
      }
      // Fast peak protection, slow release; no per-block peak normalization.
      const double peak_gain = std::pow(10.0, std::max(old_gain, gain) / 20.0);
      const double limit = peak > 0 ? std::min(1.0, .94 / (peak * peak_gain)) : 1.0;
      limiter = std::min(limit, limiter + .01);
      for (int i = 0; i < kFrame; ++i) {
        const double db = old_gain + (gain - old_gain) * (i + 1) / kFrame;
        enhanced[i] = static_cast<float>(enhanced[i] * std::pow(10.0, db / 20.0) * limiter);
      }
      auto resampled = Resample(down.get(), enhanced.data(), enhanced.size());
      std::vector<int16_t> pcm;
      for (float sample : resampled) {
        if (trim > 0) { --trim; continue; }
        if (finishing && emitted >= input_samples * output_rate / input_rate) break;
        pcm.push_back(static_cast<int16_t>(std::lround(std::clamp(sample, -.98f, .98f) * 32767)));
        ++emitted;
      }
      if (!pcm.empty()) output(pcm, speech);
      offset += kFrame;
    }
    pending.erase(pending.begin(), pending.begin() + offset);
  }
};

AudioProcessor::AudioProcessor(int input_rate, int output_rate, AudioProcessingOptions options,
                               const std::filesystem::path& model)
    : impl_(std::make_unique<Impl>(input_rate, output_rate, options, model)) {}
AudioProcessor::~AudioProcessor() = default;
void AudioProcessor::Process(const std::vector<float>& mono, const Frame& output) {
  impl_->input_samples += mono.size();
  impl_->Feed(mono, output);
}
void AudioProcessor::Finish(const Frame& output) {
  if (impl_->finishing) return;
  impl_->finishing = true;
  // Drain filter/model lookahead so pause/stop cannot drop the final phoneme.
  const std::vector<float> padding(impl_->input_rate / 10, 0);
  while (impl_->emitted < impl_->input_samples * impl_->output_rate / impl_->input_rate) {
    impl_->Feed(padding, output);
  }
}
void AudioProcessor::Reset() { impl_->Reset(); }
double AudioProcessor::gain_db() const { return impl_->gain; }

void SpeechChunker::Reset(int64_t start_ms) {
  origin_ms_ = start_ms;
  position_ = start_ = quiet_ = speech_samples_ = preview_samples_ = 0;
  pre_roll_.clear();
  pending_.clear();
}
void SpeechChunker::Add(const std::vector<int16_t>& pcm, bool speech, const Output& output) {
  if (pending_.empty() && !speech) {
    pre_roll_.insert(pre_roll_.end(), pcm.begin(), pcm.end());
    while (pre_roll_.size() > static_cast<size_t>(rate_ * 3 / 10)) pre_roll_.pop_front();
  } else {
    if (pending_.empty()) {
      start_ = position_ - static_cast<int64_t>(pre_roll_.size());
      pending_.assign(pre_roll_.begin(), pre_roll_.end());
      pre_roll_.clear();
    }
    pending_.insert(pending_.end(), pcm.begin(), pcm.end());
    if (speech) {
      quiet_ = 0;
      speech_samples_ += pcm.size();
    } else {
      quiet_ += pcm.size();
    }
  }
  position_ += pcm.size();
  // Preserve sentence context for the final decode; show replaceable snapshots
  // while speech continues instead of waiting for the full fifteen seconds.
  if (!pending_.empty() && (quiet_ >= rate_ || pending_.size() >= static_cast<size_t>(rate_ * 15))) {
    Emit(output, quiet_ < rate_);
  } else if (speech_samples_ >= rate_ / 10 &&
             static_cast<int64_t>(pending_.size()) - preview_samples_ >= rate_ * 3) {
    preview_samples_ = pending_.size();
    output({pending_, origin_ms_ + start_ * 1000 / rate_,
            origin_ms_ + position_ * 1000 / rate_, true, false});
  }
}
void SpeechChunker::Emit(const Output& output, bool continues) {
  if (!pending_.empty() && speech_samples_ >= rate_ / 10) {
    output({std::move(pending_), origin_ms_ + start_ * 1000 / rate_,
            origin_ms_ + position_ * 1000 / rate_, false, continues});
  }
  pending_.clear();
  quiet_ = speech_samples_ = preview_samples_ = 0;
}
void SpeechChunker::Finish(const Output& output) { Emit(output); pre_roll_.clear(); }
