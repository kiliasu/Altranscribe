#ifndef RUNNER_AUDIO_CAPTURE_H_
#define RUNNER_AUDIO_CAPTURE_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <vector>
#include "audio_processing.h"

// WASAPI workers never touch Flutter. Dart drains their events on the UI thread.
class AudioCapture {
 public:
  explicit AudioCapture(flutter::BinaryMessenger* messenger);
  ~AudioCapture();

 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  using List = flutter::EncodableList;
  void Capture(std::string source, std::string device_id, AudioProcessingOptions options);
  void Stop();
  void Push(Map event);
  List Drain();
  List Devices();
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::atomic<bool> stopping_{false};
  std::atomic<bool> paused_{false};
  bool streaming_ = false;
  int32_t sample_rate_ = 16000;
  std::vector<std::thread> workers_;
  std::mutex mutex_;
  List events_;
  std::chrono::steady_clock::time_point started_;
  HANDLE job_ = nullptr;
};

#endif
