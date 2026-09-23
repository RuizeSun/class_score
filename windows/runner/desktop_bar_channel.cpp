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

// Ratio of the work-area height where the "upperCenter" anchor sits (kept in
// sync with the label in lib/models/desktop_bar_style.dart).
constexpr double kUpperCenterRatio = 0.25;

// Applies the desktop schedule capsule look: frameless, no taskbar button,
// layered (opacity + optional click-through), clipped into a capsule and
// centered horizontally near the top/upper-middle/bottom of the work area.
//
// A full-width docked bar covered the desktop shortcuts on the left; a centered
// capsule leaves them visible.
void ConfigureWindow(HWND hwnd, const flutter::EncodableMap& args) {
  const double bar_width = GetDouble(args, "bar_width", 720.0);
  const double bar_height = GetDouble(args, "bar_height", 52.0);
  const double screen_margin = GetDouble(args, "screen_margin", 16.0);
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
  const LONG work_width = work.right - work.left;
  const LONG work_height = work.bottom - work.top;
  const LONG height = ToPhysical(hwnd, bar_height);
  const LONG margin = ToPhysical(hwnd, screen_margin);

  // Narrow screens: shrink the capsule instead of running off the work area.
  const LONG max_width = work_width - 2 * margin;
  LONG width = ToPhysical(hwnd, bar_width);
  if (max_width > 0 && width > max_width) width = max_width;

  // All three anchors are horizontally centered, so the desktop icons on the
  // left stay clear.
  const LONG left = work.left + (work_width - width) / 2;

  LONG top = work.top + margin;
  if (position == "bottom") {
    top = work.bottom - height - margin;
  } else if (position == "upperCenter") {
    top = work.top + static_cast<LONG>(work_height * kUpperCenterRatio);
  }

  // "desktop" layer stays below other windows; "topMost" floats above them.
  HWND insert_after = (layer == "topMost") ? HWND_TOPMOST : HWND_BOTTOM;
  SetWindowPos(hwnd, insert_after, left, top, width, height,
               SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);

  // Clip the window into a capsule (ellipse diameter = height, so both ends are
  // half circles). A window region is a 1-bit mask: outside the capsule nothing
  // is painted and no click is taken, which keeps the desktop usable even when
  // click-through is off. The system owns the region once it is set, so it must
  // only be deleted when SetWindowRgn fails.
  HRGN region = CreateRoundRectRgn(0, 0, width + 1, height + 1, height, height);
  if (region != nullptr && SetWindowRgn(hwnd, region, TRUE) == 0) {
    DeleteObject(region);
  }

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
