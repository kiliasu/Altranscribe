#include "flutter_window.h"

#include <optional>
#include <fstream>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

// The file that holds the window's place, beside the app's settings.
std::wstring PlacementFile() {
  wchar_t buffer[MAX_PATH];
  DWORD length =
      GetEnvironmentVariableW(L"ALTRANSCRIBE_DATA_DIR", buffer, MAX_PATH);
  std::wstring directory;
  if (length > 0 && length < MAX_PATH) {
    directory = buffer;
  } else {
    length = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) return L"";
    directory = std::wstring(buffer) + L"\\Altranscribe";
  }
  return directory + L"\\window.txt";
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Before the view is created, so that it is made at the final size.
  RestorePlacement();

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

void FlutterWindow::RestorePlacement() {
  const std::wstring file = PlacementFile();
  if (file.empty()) return;
  std::ifstream input(file);
  RECT rect{};
  int maximized = 0;
  if (!(input >> rect.left >> rect.top >> rect.right >> rect.bottom >>
        maximized)) {
    return;
  }
  // A display that is gone, or a size no window should have, leaves the
  // window where it opens by default.
  if (rect.right - rect.left < 200 || rect.bottom - rect.top < 200 ||
      !MonitorFromRect(&rect, MONITOR_DEFAULTTONULL)) {
    return;
  }
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  // Still hidden: the window is shown once the first frame is drawn.
  placement.showCmd = SW_HIDE;
  placement.rcNormalPosition = rect;
  SetWindowPlacement(GetHandle(), &placement);
  if (maximized) ShowMaximized();
}

void FlutterWindow::SavePlacement() {
  const std::wstring file = PlacementFile();
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (file.empty() || !GetWindowPlacement(GetHandle(), &placement)) return;
  // Minimized, it remembers how it was before.
  const bool maximized =
      placement.showCmd == SW_SHOWMAXIMIZED ||
      (placement.showCmd == SW_SHOWMINIMIZED &&
       (placement.flags & WPF_RESTORETOMAXIMIZED) != 0);
  const RECT& rect = placement.rcNormalPosition;
  std::ofstream output(file, std::ios::trunc);
  output << rect.left << ' ' << rect.top << ' ' << rect.right << ' '
         << rect.bottom << ' ' << (maximized ? 1 : 0) << '\n';
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Before Flutter sees it: the window is still whole.
  if (message == WM_CLOSE) SavePlacement();

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
    case WM_GETMINMAXINFO: {
      // The narrowest layout is a phone's; below it the page would be cut off.
      const double scale = GetDpiForWindow(hwnd) / 96.0;
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize = {static_cast<LONG>(400 * scale),
                              static_cast<LONG>(560 * scale)};
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
