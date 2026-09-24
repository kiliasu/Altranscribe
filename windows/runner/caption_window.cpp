#include "caption_window.h"

#include <algorithm>
#include <dwmapi.h>
#include <flutter/method_result_functions.h>

CaptionWindow::CaptionWindow(const flutter::DartProject& project,
                             Channel* main_channel)
    : project_(project), main_channel_(main_channel) {
  project_.set_dart_entrypoint("captionMain");
}

CaptionWindow::~CaptionWindow() { Destroy(); }

bool CaptionWindow::Present(const Value& snapshot) {
  if (!GetHandle()) {
    if (!Create(L"Altranscribe \u00b7 Captions", Point(120, 120), Size(720, 360))) {
      return false;
    }
    // Position within the current display's work area, independent of the main
    // window's minimized state (this window deliberately has no owner).
    POINT cursor;
    GetCursorPos(&cursor);
    MONITORINFO monitor = {sizeof(MONITORINFO)};
    GetMonitorInfo(MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST), &monitor);
    RECT rect;
    GetWindowRect(GetHandle(), &rect);
    const RECT area = monitor.rcWork;
    SetWindowPos(GetHandle(), HWND_TOPMOST,
                 area.left + ((area.right - area.left) - (rect.right - rect.left)) / 2,
                 std::max(area.top, area.bottom - (rect.bottom - rect.top) - 48),
                 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
  }
  visible_ = true;
  Update(snapshot);
  if (ready_) ShowWindow(GetHandle(), SW_SHOWNOACTIVATE);
  return true;
}

void CaptionWindow::Update(const Value& snapshot) {
  snapshot_ = snapshot;
  if (channel_) channel_->InvokeMethod("snapshot", std::make_unique<Value>(snapshot));
  if (GetHandle()) {
    const auto* map = std::get_if<flutter::EncodableMap>(&snapshot);
    if (map) {
      auto prefs = map->find(Value("preferences"));
      if (prefs != map->end()) {
        const auto* values = std::get_if<flutter::EncodableMap>(&prefs->second);
        if (values) {
          auto opacity = values->find(Value("opacity"));
          if (opacity != values->end()) {
            const auto* number = std::get_if<double>(&opacity->second);
            if (number) SetLayeredWindowAttributes(GetHandle(), 0,
                static_cast<BYTE>(std::clamp(*number, 0.4, 1.0) * 255), LWA_ALPHA);
          }
        }
      }
    }
  }
}

void CaptionWindow::Hide() {
  visible_ = false;
  if (channel_) channel_->InvokeMethod("hidden", nullptr);
  if (GetHandle()) ShowWindow(GetHandle(), SW_HIDE);
}

bool CaptionWindow::OnCreate() {
  const auto hwnd = GetHandle();
  SetWindowLongPtr(hwnd, GWL_STYLE, WS_POPUP | WS_THICKFRAME | WS_CLIPCHILDREN);
  SetWindowLongPtr(hwnd, GWL_EXSTYLE, WS_EX_TOOLWINDOW | WS_EX_LAYERED);
  SetLayeredWindowAttributes(hwnd, 0, 240, LWA_ALPHA);
  const DWORD rounded = 2; // DWMWCP_ROUND on Windows 11; ignored on Windows 10.
  DwmSetWindowAttribute(hwnd, 33, &rounded, sizeof(rounded));
  SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  const RECT frame = GetClientArea();
  controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right, frame.bottom, project_);
  if (!controller_->engine() || !controller_->view()) return false;
  channel_ = std::make_unique<Channel>(controller_->engine()->messenger(),
      "altranscribe/captions", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "ready") {
      result->Success(snapshot_);
    } else if (call.method_name() == "drag") {
      result->Success();
      ReleaseCapture();
      PostMessage(GetHandle(), WM_NCLBUTTONDOWN, HTCAPTION, 0);
    } else if (call.method_name() == "action") {
      // Keep the async result alive until the main engine completes the action,
      // especially pausing capture before a discard confirmation is displayed.
      auto reply = std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
      main_channel_->InvokeMethod("action", std::make_unique<Value>(*call.arguments()),
          std::make_unique<flutter::MethodResultFunctions<Value>>(
            [reply](const Value* value) { value ? reply->Success(*value) : reply->Success(); },
            [reply](const std::string& code, const std::string& message, const Value* details) {
              details ? reply->Error(code, message, *details) : reply->Error(code, message);
            },
            [reply]() { reply->NotImplemented(); }));
    } else {
      result->NotImplemented();
    }
  });
  SetChildContent(controller_->view()->GetNativeWindow(), false);
  controller_->engine()->SetNextFrameCallback([this]() {
    ready_ = true;
    if (visible_) ShowWindow(GetHandle(), SW_SHOWNOACTIVATE);
  });
  controller_->ForceRedraw();
  return true;
}

void CaptionWindow::OnDestroy() {
  ready_ = false;
  channel_.reset();
  controller_.reset();
  Win32Window::OnDestroy();
}

LRESULT CaptionWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) noexcept {
  if (message == WM_CLOSE) {
    Hide();
    main_channel_->InvokeMethod("closed", nullptr);
    return 0;
  }
  if (message == WM_GETMINMAXINFO) {
    const double scale = GetDpiForWindow(hwnd) / 96.0;
    auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
    info->ptMinTrackSize = {static_cast<LONG>(420 * scale), static_cast<LONG>(240 * scale)};
    return 0;
  }
  if (controller_) {
    auto result = controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (result) return *result;
    if (message == WM_FONTCHANGE) controller_->engine()->ReloadSystemFonts();
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
