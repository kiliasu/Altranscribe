#include "audio_processing.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <random>
#include <stdexcept>

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
double Rms(const std::vector<int16_t>& pcm, size_t start = 0) {
  double energy = 0;
  for (size_t i = start; i < pcm.size(); ++i) energy += static_cast<double>(pcm[i]) * pcm[i];
  return std::sqrt(energy / std::max<size_t>(1, pcm.size() - start)) / 32768;
}
void Boundaries() {
  SpeechChunker chunker(16000);
  std::vector<SpeechChunk> chunks;
  std::vector<SpeechChunk> previews;
  auto collect = [&](SpeechChunk chunk) {
    (chunk.partial ? previews : chunks).push_back(std::move(chunk));
  };
  auto feed = [&](int frames, bool speech, int16_t value = 123) {
    for (int i = 0; i < frames; ++i) chunker.Add(std::vector<int16_t>(160, value), speech, collect);
  };
  chunker.Reset(1000);
  feed(30, false, 0);
  feed(550, true);
  feed(65, false, 0); // A breath in the middle of a sentence.
  feed(230, true, 456);
  Require(chunks.empty(), "A short pause must not split the sentence");
  Require(previews.size() == 2 && previews.front().end_ms == 4000,
          "Long speech must appear after three seconds, before the final boundary");
  Require(previews[0].start_ms == previews[1].start_ms &&
          previews[0].pcm.size() < previews[1].pcm.size(),
          "Previews must retain the earlier audio so later words can revise it");
  feed(100, false, 0);
  Require(chunks.size() == 1, "A natural pause must finalize the sentence");
  Require(!chunks[0].continues, "A natural pause must seal the sentence");
  Require(chunks[0].start_ms == 1000 && chunks[0].end_ms == 10750, "Wrong sentence timestamps");
  Require(std::count(chunks[0].pcm.begin(), chunks[0].pcm.end(), 456) == 230 * 160, "Tail was lost");
  chunks.clear();
  previews.clear();
  chunker.Reset(20000);
  feed(1600, true);
  chunker.Finish(collect);
  Require(chunks.size() == 2, "Continuous speech must have bounded latency");
  Require(previews.size() == 4 && chunks[0].continues && !chunks[1].continues,
          "Continuous previews, hard cap and stop must have distinct boundaries");
  Require(chunks[0].end_ms == chunks[1].start_ms, "Hard boundary lost or duplicated samples");
  Require(chunks[0].pcm.size() + chunks[1].pcm.size() == 1600 * 160,
          "Preview snapshots must not consume or duplicate final audio");
  chunks.clear();
  chunker.Reset(40000);
  feed(18, true);
  chunker.Finish(collect);
  Require(chunks.size() == 1 && chunks[0].pcm.size() == 2880, "Stop lost a short final word");
}
#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
#else
int main(int argc, char** argv) {
#endif
  try {
    if (argc < 2) return 2;
    Boundaries();
    const auto started = std::chrono::steady_clock::now();
    for (const int rate : {16000, 24000, 44100, 48000}) {
      for (const int target : {16000, 24000}) {
        AudioProcessor processor(rate, target, {false, false}, argv[1]);
        std::vector<float> input(rate * 2 + 73);
        for (size_t i = 0; i < input.size(); ++i) input[i] = static_cast<float>(.1 * std::sin(6.2831853 * 440 * i / rate));
        std::vector<int16_t> output;
        auto collect = [&](const std::vector<int16_t>& pcm, bool) { output.insert(output.end(), pcm.begin(), pcm.end()); };
        for (size_t offset = 0; offset < input.size(); offset += 137) {
          processor.Process(std::vector<float>(input.begin() + offset, input.begin() + std::min(input.size(), offset + 137)), collect);
        }
        processor.Finish(collect);
        Require(output.size() == input.size() * target / rate, "Resampling or stop changed duration");
        Require(Rms(output, target / 10) > .06, "Disabled enhancement damaged speech band");
        processor.Reset();
        output.clear();
        processor.Process(std::vector<float>(rate, 0), collect);
        processor.Finish(collect);
        Require(Rms(output) == 0, "Previous session/filter state leaked after reset");
      }
    }
    AudioProcessor processor(48000, 16000, {true, true}, argv[1]);
    std::mt19937 random(7);
    std::normal_distribution<float> noise(0, .03f);
    std::vector<float> input(48000 * 3);
    for (auto& sample : input) sample = noise(random);
    std::vector<int16_t> output;
    processor.Process(input, [&](const std::vector<int16_t>& pcm, bool) { output.insert(output.end(), pcm.begin(), pcm.end()); });
    processor.Finish([&](const std::vector<int16_t>& pcm, bool) { output.insert(output.end(), pcm.begin(), pcm.end()); });
    Require(Rms(output, 16000) < .015, "Noise reduction did not reduce stationary noise");
    Require(processor.gain_db() < 1, "AGC amplified noise-only input");
    std::cout << "noise RMS=" << Rms(output, 16000) << " gain=" << processor.gain_db() << "dB\n";
    AudioProcessor peaks(48000, 16000, {false, true}, argv[1]);
    input.resize(48000);
    for (size_t i = 0; i < input.size(); ++i) {
      input[i] = static_cast<float>((i < 9600 ? .999 : .2) * std::sin(6.2831853 * 1000 * i / 48000));
    }
    output.clear();
    auto collect = [&](const std::vector<int16_t>& pcm, bool) { output.insert(output.end(), pcm.begin(), pcm.end()); };
    peaks.Process(input, collect);
    peaks.Finish(collect);
    Require(std::all_of(output.begin(), output.end(), [](int16_t sample) {
      return std::abs(static_cast<int>(sample)) <= 32112;
    }), "A loud transient clipped or overflowed the PCM output");
    Require(Rms(output, 12800) > .13, "Peak protection failed to recover the following quiet audio");
    std::cout << "Native boundaries, pause/reset, exact sample counts, noise suppression and peak recovery passed.\n";
    std::cout << "test elapsed=" << std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() << "s\n";
    // Optional raw-float input allows the same DSP to be checked with real speech fixtures.
    if (argc == 4) {
      std::ifstream input_file(std::filesystem::path(argv[2]), std::ios::binary);
      std::vector<char> bytes((std::istreambuf_iterator<char>(input_file)), {});
      std::vector<float> speech(bytes.size() / sizeof(float));
      std::memcpy(speech.data(), bytes.data(), speech.size() * sizeof(float));
      AudioProcessor speech_processor(48000, 16000, {true, true}, argv[1]);
      std::ofstream output_file(std::filesystem::path(argv[3]), std::ios::binary);
      auto write = [&](const std::vector<int16_t>& pcm, bool) {
        output_file.write(reinterpret_cast<const char*>(pcm.data()), pcm.size() * sizeof(int16_t));
      };
      speech_processor.Process(speech, write);
      speech_processor.Finish(write);
      std::cout << "speech gain=" << speech_processor.gain_db() << "dB\n";
    }
    return 0;
  } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
