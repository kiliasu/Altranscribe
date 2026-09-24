#ifndef RUNNER_CAPTION_WINDOW_H_
#define RUNNER_CAPTION_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include "win32_window.h"

// A display-only engine. Audio capture and inference remain in the main engine.
class CaptionWindow : public Win32Window {
 public:
  using Value = flutter::EncodableValue;
  using Channel = flutter::MethodChannel<Value>;
  CaptionWindow(const flutter::DartProject& project, Channel* main_channel);
  ~CaptionWindow() override;
  bool Present(const Value& snapshot);
  void Update(const Value& snapshot);
  void Hide();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept override;

 private:
  flutter::DartProject project_;
  Channel* main_channel_;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  std::unique_ptr<Channel> channel_;
  Value snapshot_;
  bool visible_ = false;
  bool ready_ = false;
};
#endif
