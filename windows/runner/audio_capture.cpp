#include "audio_capture.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ksmedia.h>
#include <wincrypt.h>
#include <wrl/client.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <sstream>
#include <stdexcept>

using Microsoft::WRL::ComPtr;
namespace {
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;

void Check(HRESULT hr, const char* operation) {
  if (FAILED(hr)) {
    std::ostringstream message;
    message << operation << " (0x" << std::hex << static_cast<unsigned long>(hr) << ")";
    throw std::runtime_error(message.str());
  }
}
std::string Utf8(const wchar_t* value) {
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), size, nullptr, nullptr);
  if (!result.empty()) result.pop_back();
  return result;
}
std::wstring Wide(const std::string& value) {
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), size);
  return result;
}
template <typename T> T Argument(const M& args, const char* key, T fallback) {
  auto it = args.find(V(key));
  if (it == args.end()) return fallback;
  auto value = std::get_if<T>(&it->second);
  if (!value) throw std::runtime_error(std::string("Invalid argument: ") + key);
  return *value;
}
struct ComScope {
  ComScope() { Check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "COM initialization"); }
  ~ComScope() { CoUninitialize(); }
};
struct WaveFormatDeleter { void operator()(WAVEFORMATEX* p) const { CoTaskMemFree(p); } };
}

AudioCapture::AudioCapture(flutter::BinaryMessenger* messenger) {
  job_ = CreateJobObject(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (job_ && !SetInformationJobObject(job_, JobObjectExtendedLimitInformation,
                                      &limits, sizeof(limits))) {
    CloseHandle(job_);
    job_ = nullptr;
  }
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "altranscribe/audio", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    try {
      const M empty;
      const M* args = call.arguments() && !call.arguments()->IsNull()
                          ? std::get_if<M>(call.arguments()) : &empty;
      if (!args) throw std::runtime_error("Invalid arguments");
      if (call.method_name() == "devices") {
        result->Success(V(Devices()));
      } else if (call.method_name() == "start") {
        if (!workers_.empty()) throw std::runtime_error("Capture already running");
        const bool mic = Argument(*args, "microphone", false);
        const bool system = Argument(*args, "system", false);
        if (!mic && !system) throw std::runtime_error("No audio source selected");
        streaming_ = Argument(*args, "streaming", false);
        sample_rate_ = Argument<int32_t>(*args, "sampleRate", 16000);
        if (sample_rate_ != 16000 && sample_rate_ != 24000) {
          throw std::runtime_error("Unsupported capture sample rate");
        }
        events_.clear();
        stopping_ = false;
        paused_ = false;
        started_ = std::chrono::steady_clock::now();
        if (mic) workers_.emplace_back(&AudioCapture::Capture, this, "microphone",
                                      Argument(*args, "microphoneDevice", std::string()),
                                      AudioProcessingOptions{Argument(*args, "microphoneDenoise", true),
                                                             Argument(*args, "microphoneAutoGain", true)});
        if (system) workers_.emplace_back(&AudioCapture::Capture, this, "system",
                                         Argument(*args, "systemDevice", std::string()),
                                         AudioProcessingOptions{Argument(*args, "systemDenoise", false),
                                                                Argument(*args, "systemAutoGain", false)});
        result->Success();
      } else if (call.method_name() == "poll") {
        result->Success(V(Drain()));
      } else if (call.method_name() == "pause") {
        paused_ = Argument(*args, "paused", false);
        result->Success();
      } else if (call.method_name() == "stop") {
        Stop();
        result->Success(V(Drain()));
      } else if (call.method_name() == "protectSecret" || call.method_name() == "unprotectSecret") {
        auto bytes = Argument(*args, "bytes", std::vector<uint8_t>());
        if (bytes.empty() || bytes.size() > 65536) throw std::runtime_error("Invalid credential");
        DATA_BLOB input{static_cast<DWORD>(bytes.size()), bytes.data()};
        DATA_BLOB output{};
        const bool protect = call.method_name() == "protectSecret";
        const BOOL success = protect
            ? CryptProtectData(&input, L"Altranscribe API key", nullptr, nullptr,
                               nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)
            : CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                                 CRYPTPROTECT_UI_FORBIDDEN, &output);
        SecureZeroMemory(bytes.data(), bytes.size());
        if (!success) throw std::runtime_error("Windows credential encryption failed");
        std::vector<uint8_t> value(output.pbData, output.pbData + output.cbData);
        SecureZeroMemory(output.pbData, output.cbData);
        LocalFree(output.pbData);
        result->Success(V(value));
        SecureZeroMemory(value.data(), value.size());
      } else if (call.method_name() == "ownProcess") {
        const auto pid = Argument<int32_t>(*args, "pid", 0);
        HANDLE process = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE,
                                     static_cast<DWORD>(pid));
        const bool assigned = process && job_ && AssignProcessToJobObject(job_, process);
        if (process) CloseHandle(process);
        if (!assigned) throw std::runtime_error("Cannot attach Whisper to application lifetime");
        result->Success();
      } else {
        result->NotImplemented();
      }
    } catch (const std::exception& e) {
      result->Error("audio", e.what());
    }
  });
}

AudioCapture::~AudioCapture() {
  channel_->SetMethodCallHandler(nullptr);
  Stop();
  if (job_) CloseHandle(job_);
}

void AudioCapture::Stop() {
  stopping_ = true;
  for (auto& worker : workers_) if (worker.joinable()) worker.join();
  workers_.clear();
}

void AudioCapture::Push(Map event) {
  std::lock_guard<std::mutex> lock(mutex_);
  // A stalled Dart isolate must not accumulate unlimited audio in native memory.
  if (events_.size() >= 256) {
    events_.clear();
    events_.emplace_back(M{{V("type"), V("error")}, {V("source"), V("audio")},
        {V("message"), V("Audio event buffer overflow; capture stopped")}});
    stopping_ = true;
    return;
  }
  events_.emplace_back(std::move(event));
}

AudioCapture::List AudioCapture::Drain() {
  std::lock_guard<std::mutex> lock(mutex_);
  List result;
  result.swap(events_);
  return result;
}

AudioCapture::List AudioCapture::Devices() {
  ComPtr<IMMDeviceEnumerator> enumerator;
  Check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                         IID_PPV_ARGS(&enumerator)), "List audio devices");
  List result;
  for (const auto flow : {eCapture, eRender}) {
    ComPtr<IMMDeviceCollection> devices;
    Check(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &devices), "Audio endpoints");
    UINT count = 0;
    Check(devices->GetCount(&count), "Audio endpoint count");
    for (UINT i = 0; i < count; ++i) {
      ComPtr<IMMDevice> device;
      Check(devices->Item(i, &device), "Audio endpoint");
      LPWSTR id = nullptr;
      Check(device->GetId(&id), "Audio endpoint ID");
      const std::string device_id = Utf8(id);
      CoTaskMemFree(id);
      ComPtr<IPropertyStore> properties;
      Check(device->OpenPropertyStore(STGM_READ, &properties), "Audio endpoint properties");
      PROPVARIANT name;
      PropVariantInit(&name);
      Check(properties->GetValue(PKEY_Device_FriendlyName, &name), "Audio endpoint name");
      const std::string label = name.vt == VT_LPWSTR ? Utf8(name.pwszVal) : device_id;
      PropVariantClear(&name);
      result.emplace_back(M{{V("id"), V(device_id)}, {V("name"), V(label)},
                            {V("source"), V(flow == eCapture ? "microphone" : "system")}});
    }
  }
  return result;
}

void AudioCapture::Capture(std::string source, std::string device_id, AudioProcessingOptions options) {
  try {
    ComScope com;
    ComPtr<IMMDeviceEnumerator> enumerator;
    Check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                           IID_PPV_ARGS(&enumerator)), "Open audio devices");
    ComPtr<IMMDevice> device;
    if (device_id.empty()) {
      Check(enumerator->GetDefaultAudioEndpoint(source == "system" ? eRender : eCapture,
                                                eConsole, &device), "Default audio device");
    } else {
      Check(enumerator->GetDevice(Wide(device_id).c_str(), &device), "Selected audio device");
    }
    ComPtr<IAudioClient> client;
    Check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                           reinterpret_cast<void**>(client.GetAddressOf())), "Activate WASAPI");
    WAVEFORMATEX* raw_format = nullptr;
    Check(client->GetMixFormat(&raw_format), "Audio format");
    std::unique_ptr<WAVEFORMATEX, WaveFormatDeleter> format(raw_format);
    bool floating = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    bool pcm = format->wFormatTag == WAVE_FORMAT_PCM;
    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= 22) {
      const auto* extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format.get());
      floating = IsEqualGUID(extended->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
      pcm = IsEqualGUID(extended->SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
    }
    const int bits = format->wBitsPerSample;
    if ((!floating || bits != 32) && (!pcm || (bits != 16 && bits != 24 && bits != 32))) {
      throw std::runtime_error("Unsupported WASAPI sample format");
    }
    Check(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                              source == "system" ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0,
                              1000000, 0, format.get(), nullptr), "Initialize WASAPI");
    ComPtr<IAudioCaptureClient> capture;
    Check(client->GetService(IID_PPV_ARGS(&capture)), "WASAPI capture service");
    std::array<wchar_t, 32768> executable_path{};
    if (!GetModuleFileNameW(nullptr, executable_path.data(), static_cast<DWORD>(executable_path.size()))) {
      throw std::runtime_error("Cannot locate bundled audio model");
    }
    AudioProcessor processor(format->nSamplesPerSec, sample_rate_, options,
        std::filesystem::path(executable_path.data()).parent_path() / L"data/rnnoise-model.bin");
    SpeechChunker chunker(sample_rate_);
    Check(client->Start(), "Start audio capture");
    Push(M{{V("type"), V("ready")}, {V("source"), V(source)}});

    std::vector<uint8_t> pcm_bytes;
    pcm_bytes.reserve(sample_rate_ / 5);
    int64_t stream_samples = 0;
    int64_t origin_ms = 0;
    bool has_audio = false;
    double packet_level = 0;
    bool was_paused = false;
    auto last_level = std::chrono::steady_clock::now();
    auto last_packet = last_level;
    auto last_silence = last_level;
    auto milliseconds = [this]() -> int64_t {
      return std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - started_).count();
    };
    auto send_chunk = [&](SpeechChunk chunk) {
      std::vector<uint8_t> bytes(chunk.pcm.size() * 2);
      std::memcpy(bytes.data(), chunk.pcm.data(), bytes.size());
      Push(M{{V("type"), V("chunk")}, {V("source"), V(source)},
             {V("startMs"), V(chunk.start_ms)}, {V("endMs"), V(chunk.end_ms)},
             {V("partial"), V(chunk.partial)}, {V("continues"), V(chunk.continues)},
             {V("pcm"), V(std::move(bytes))}});
    };
    auto flush_stream = [&]() {
      const int64_t samples = static_cast<int64_t>(pcm_bytes.size() / 2);
      if (samples > 0) {
        Push(M{{V("type"), V("frame")}, {V("source"), V(source)},
               {V("startMs"), V(origin_ms + stream_samples * 1000 / sample_rate_)},
               {V("endMs"), V(origin_ms + (stream_samples + samples) * 1000 / sample_rate_)},
               {V("pcm"), V(std::move(pcm_bytes))}});
        stream_samples += samples;
      }
      pcm_bytes.clear();
    };
    auto on_frame = [&](const std::vector<int16_t>& pcm_frame, bool speech) {
      if (streaming_) {
        const auto* bytes = reinterpret_cast<const uint8_t*>(pcm_frame.data());
        pcm_bytes.insert(pcm_bytes.end(), bytes, bytes + pcm_frame.size() * 2);
        if (pcm_bytes.size() >= static_cast<size_t>(sample_rate_ / 5)) flush_stream();
      } else {
        chunker.Add(pcm_frame, speech, send_chunk);
      }
    };
    auto drain = [&]() {
      processor.Finish(on_frame);
      if (streaming_) flush_stream(); else chunker.Finish(send_chunk);
    };
    auto reset = [&]() {
      processor.Reset();
      has_audio = false;
      stream_samples = 0;
      pcm_bytes.clear();
      last_packet = last_silence = std::chrono::steady_clock::now();
    };
    while (!stopping_) {
      const auto now = std::chrono::steady_clock::now();
      const bool paused = paused_;
      if (paused != was_paused) {
        if (paused) {
          Check(client->Stop(), "Pause WASAPI");
          drain();
          Check(client->Reset(), "Clear paused audio");
          if (streaming_) Push(M{{V("type"), V("paused")}, {V("source"), V(source)},
                                  {V("endMs"), V(milliseconds())}});
        } else {
          reset();
          Check(client->Start(), "Resume WASAPI");
        }
        was_paused = paused;
      }
      if (paused) {
        if (now - last_level >= std::chrono::milliseconds(200)) {
          Push(M{{V("type"), V("level")}, {V("source"), V(source)}, {V("level"), V(0.0)}});
          last_level = now;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        continue;
      }
      UINT32 available = 0;
      Check(capture->GetNextPacketSize(&available), "Read audio packet size");
      while (available && !stopping_) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        Check(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr), "Read audio buffer");
        // No throwing operations before ReleaseBuffer except memory allocation.
        std::vector<float> mono_samples;
        const bool discontinuity = (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) && has_audio;
        if (!paused) {
          mono_samples.reserve(frames);
          double sum = 0;
          for (UINT32 frame = 0; frame < frames; ++frame) {
            double mono = 0;
            if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
              for (WORD ch = 0; ch < format->nChannels; ++ch) {
                const BYTE* sample = data + frame * format->nBlockAlign + ch * (bits / 8);
                if (floating) {
                  float value;
                  std::memcpy(&value, sample, sizeof(value));
                  if (std::isfinite(value)) mono += value;
                } else if (bits == 16) {
                  int16_t value;
                  std::memcpy(&value, sample, sizeof(value));
                  mono += value / 32768.0;
                } else if (bits == 24) {
                  int32_t value = sample[0] | (sample[1] << 8) | (sample[2] << 16);
                  if (value & 0x800000) value |= ~0xffffff;
                  mono += value / 8388608.0;
                } else {
                  int32_t value;
                  std::memcpy(&value, sample, sizeof(value));
                  mono += value / 2147483648.0;
                }
              }
              mono /= format->nChannels;
            }
            mono = std::clamp(mono, -1.0, 1.0);
            sum += mono * mono;
            mono_samples.push_back(static_cast<float>(mono));
          }
          packet_level = frames ? std::sqrt(sum / frames) : 0;
        }
        Check(capture->ReleaseBuffer(frames), "Release audio buffer");
        if (discontinuity) {
          drain();
          reset();
          Push(M{{V("type"), V("gap")}, {V("source"), V(source)}});
        }
        if (!mono_samples.empty()) {
          if (!has_audio) {
            origin_ms = std::max<int64_t>(0, milliseconds() - frames * 1000 / format->nSamplesPerSec);
            chunker.Reset(origin_ms);
            has_audio = true;
          }
          processor.Process(mono_samples, on_frame);
        }
        last_packet = now;
        last_silence = now;
        Check(capture->GetNextPacketSize(&available), "Read next audio packet");
      }
      // Idle loopback devices can stop producing packets. Cloud VAD/translation
      // still needs continuous silence so it can finalize the last spoken phrase.
      if (has_audio && now - last_packet >= std::chrono::milliseconds(100) &&
          now - last_silence >= std::chrono::milliseconds(100)) {
        processor.Process(std::vector<float>(format->nSamplesPerSec / 10, 0), on_frame);
        last_silence = now;
        packet_level = 0;
      }
      if (now - last_level >= std::chrono::milliseconds(200)) {
        Push(M{{V("type"), V("level")}, {V("source"), V(source)},
               {V("level"), V(paused ? 0.0 : packet_level)}});
        last_level = now;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    Check(client->Stop(), "Stop WASAPI");
    drain();
  } catch (const std::exception& e) {
    Push(M{{V("type"), V("error")}, {V("source"), V(source)}, {V("message"), V(e.what())}});
  }
}
