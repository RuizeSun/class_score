#include "desktop_bar_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

namespace {

constexpr char kChannelName[] = "class_score/desktop_bar_window";

// Keeps the method channels alive: the engine only holds a raw pointer to the
// handler, so the channel object must outlive the engine.
std::vector<std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
    g_channels;

double GetDouble(const flutter::EncodableMap& args, const char* key,
                 double fallback) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return fallback;
  if (auto* value = std::get_if<double>(&it->second)) return *value;
  if (auto* value = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  if (auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  return fallback;
}

bool GetBool(const flutter::EncodableMap& args, const char* key, bool fallback) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return fallback;
  if (auto* value = std::get_if<bool>(&it->second)) return *value;
  return fallback;
}

std::string GetString(const flutter::EncodableMap& args, const char* key,
                      const char* fallback) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return fallback;
  if (auto* value = std::get_if<std::string>(&it->second)) return *value;
  return fallback;
}

// Flutter works in logical pixels, Win32 in physical ones.
LONG ToPhysical(HWND hwnd, double logical) {
  const UINT dpi = GetDpiForWindow(hwnd);
  const double scale = (dpi == 0 ? 96.0 : static_cast<double>(dpi)) / 96.0;
  return static_cast<LONG>(logical * scale + 0.5);
}

// Work area (taskbar excluded) of the monitor the window currently sits on.
RECT GetWorkArea(HWND hwnd) {
  MONITORINFO info{};
  info.cbSize = sizeof(MONITORINFO);
  HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  if (monitor != nullptr && GetMonitorInfo(monitor, &info)) {
    return info.rcWork;
  }
  RECT fallback{};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &fallback, 0);
  return fallback;
}

// Applies the desktop bar look: frameless, no taskbar button, layered
// (opacity + optional click-through), docked to the top/bottom of the screen.
void ConfigureWindow(HWND hwnd, const flutter::EncodableMap& args) {
  const double bar_height = GetDouble(args, "bar_height", 52.0);
  const double opacity = GetDouble(args, "opacity", 0.92);
  const bool click_through = GetBool(args, "click_through", true);
  const std::string position = GetString(args, "position", "top");
  const std::string layer = GetString(args, "layer", "desktop");

  LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
  style &= ~(WS_OVERLAPPEDWINDOW);
  style |= WS_POPUP;
  SetWindowLongPtr(hwnd, GWL_STYLE, style);

  LONG_PTR ex_style = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  ex_style |= WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
  if (click_through) {
    ex_style |= WS_EX_TRANSPARENT;
  } else {
    ex_style &= ~WS_EX_TRANSPARENT;
  }
  SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex_style);

  const double clamped = opacity < 0.0 ? 0.0 : (opacity > 1.0 ? 1.0 : opacity);
  SetLayeredWindowAttributes(hwnd, 0, static_cast<BYTE>(clamped * 255),
                             LWA_ALPHA);

  const RECT work = GetWorkArea(hwnd);
  const LONG height = ToPhysical(hwnd, bar_height);
  const LONG top = (position == "bottom") ? work.bottom - height : work.top;

  // "desktop" layer stays below other windows; "topMost" floats above them.
  HWND insert_after = (layer == "topMost") ? HWND_TOPMOST : HWND_BOTTOM;
  SetWindowPos(hwnd, insert_after, work.left, top, work.right - work.left,
               height,
               SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
}

void HandleConfigure(
    HWND hwnd, const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    result->Error("INVALID_ARGUMENTS", "configure expects a map");
    return;
  }
  ConfigureWindow(hwnd, *args);
  result->Success();
}

}  // namespace

void RegisterDesktopBarWindowChannel(
    flutter::FlutterViewController* view_controller) {
  if (view_controller == nullptr || view_controller->view() == nullptr) {
    return;
  }

  // The Flutter view is a child window; the styled top-level window is its root.
  HWND hwnd = GetAncestor(view_controller->view()->GetNativeWindow(), GA_ROOT);
  if (hwnd == nullptr) {
    return;
  }

  auto channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          view_controller->engine()->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [hwnd](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "configure") {
          HandleConfigure(hwnd, call, std::move(result));
          return;
        }
        if (call.method_name() == "close") {
          PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  g_channels.push_back(std::move(channel));
}
