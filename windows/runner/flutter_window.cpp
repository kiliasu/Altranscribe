#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  audio_capture_ = std::make_unique<AudioCapture>(flutter_controller_->engine()->messenger());
  caption_channel_ = std::make_unique<CaptionWindow::Channel>(
      flutter_controller_->engine()->messenger(), "altranscribe/captions",
      &flutter::StandardMethodCodec::GetInstance());
  caption_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "show") {
      if (!caption_window_) caption_window_ = std::make_unique<CaptionWindow>(project_, caption_channel_.get());
      if (call.arguments() && caption_window_->Present(*call.arguments())) result->Success();
      else result->Error("captionWindowFailed", "Could not open captions");
    } else if (call.method_name() == "update") {
      if (caption_window_ && call.arguments()) caption_window_->Update(*call.arguments());
      result->Success();
    } else if (call.method_name() == "hide") {
      if (caption_window_) caption_window_->Hide();
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  caption_window_.reset();
  caption_channel_.reset();
  audio_capture_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
