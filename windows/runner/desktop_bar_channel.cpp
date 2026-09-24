#include "desktop_bar_channel.h"

#include <dwmapi.h>
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

// Whether a normal program window currently owns the foreground (used by the
// dual-appearance feature: desktop look vs. foreground look).
//
// "Foreground program" = after normalizing the foreground handle (see below),
// the candidate is a visible, non-minimized, non-cloaked top-level window that
// is neither the desktop shell (icons / taskbar popups) nor the bar window
// itself. The bar's own main window counts as a program, so opening the app
// switches the capsule to the foreground look too.
//
// Detection is pull-based: Dart asks "get_foreground" once per payload tick
// instead of native pushing events, so no timer or native-to-Dart call
// outlives the engine (the channel's messenger pointer would dangle after
// teardown).

// DWMWA_CLOAKED (dwmapi.h, Win8+): windows hidden by virtual desktops or
// UWP suspension stay "visible" to older checks; literal avoids SDK guards.
constexpr DWORD kDwmwaCloaked = 14;

// Desktop shell windows and their popups: clicking the desktop, the taskbar or
// the Start menu makes one of these the foreground window, but none of them is
// "a program in front of the desktop".
constexpr const wchar_t* kShellClasses[] = {
    L"Progman",
    L"WorkerW",
    L"Shell_TrayWnd",
    L"Shell_SecondaryTrayWnd",
    L"NotifyIconOverflowWindow",
    L"Windows.UI.Core.CoreWindow",
    // Taskbar thumbnails / hover flyouts / jump lists and the like: transient
    // shell UI that belongs to the taskbar, not to a user program.
    L"TaskListThumbnailWnd",
    L"TaskListOverlayWnd",
    L"ContentUI.Host",
    L"Shell_Flyout",
    L"DV2ControlHost",
    L"MultitaskingViewFrame",
};

bool IsShellWindow(HWND hwnd) {
  wchar_t class_name[64] = L"";
  GetClassNameW(hwnd, class_name, 64);
  for (const wchar_t* shell_class : kShellClasses) {
    if (lstrcmpW(class_name, shell_class) == 0) return true;
  }
  return false;
}

// Cloaked = hidden by a virtual desktop / suspended UWP but still "visible"
// to IsWindowVisible; such a window is not something the user is looking at.
bool IsWindowCloaked(HWND hwnd) {
  DWORD cloaked = 0;
  return SUCCEEDED(DwmGetWindowAttribute(hwnd, kDwmwaCloaked, &cloaked,
                                         sizeof(cloaked))) &&
         cloaked != 0;
}

// Usable = a window the user can actually see right now: style-visible, not
// minimized, not cloaked by a virtual desktop, not a fully transparent
// layered ghost, and not parked off every monitor.
bool IsUsableWindow(HWND hwnd) {
  if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || IsWindowCloaked(hwnd)) {
    return false;
  }

  // Fully transparent layered windows (alpha 0) are invisible in practice;
  // many apps keep such popups around as leftovers. The call fails for
  // windows without WS_EX_LAYERED -> treat them as opaque.
  DWORD flags = 0;
  BYTE alpha = 255;
  COLORREF key = 0;
  if (GetLayeredWindowAttributes(hwnd, &key, &alpha, &flags) &&
      (flags & LWA_ALPHA) != 0 && alpha == 0) {
    return false;
  }

  // Zero-size or fully off-screen rectangles mean nothing is being shown.
  RECT rect{};
  if (!GetWindowRect(hwnd, &rect)) return false;
  if (rect.right - rect.left <= 0 || rect.bottom - rect.top <= 0) {
    return false;
  }
  return MonitorFromRect(&rect, MONITOR_DEFAULTTONULL) != nullptr;
}

bool IsProgramInForeground(HWND bar) {
  // Classic Win32 quirk: minimizing a window does NOT move the foreground
  // away from it - GetForegroundWindow() keeps returning the minimized
  // window until the user clicks somewhere else. Instead of trusting that
  // single handle, walk down the Z-order past stale/hidden candidates and
  // judge the next real window: another visible program keeps the foreground
  // look, the shell (or nothing left to inspect) means the desktop look.
  HWND candidate = GetForegroundWindow();
  // Bounded walk: normal cases resolve within a couple of hops (the stale
  // handle, maybe the bar itself, then the next real window); if the chain
  // only hides dead ends, falling through to "desktop" is the safe default.
  for (int hops = 0; candidate != nullptr && hops < 8; ++hops) {
    if (candidate == bar) {
      candidate = GetWindow(candidate, GW_HWNDNEXT);
      continue;
    }
    if (!IsUsableWindow(candidate)) {
      candidate = GetWindow(candidate, GW_HWNDNEXT);
      continue;
    }
    if (IsShellWindow(candidate)) return false;
    return true;
  }
  return false;
}

// ---- Fade transition for the desktop <-> foreground appearance switch ----
//
// Dart orchestrates the sequence: fade_out (old look fades away in place,
// geometry and content still match) -> configure at alpha 0 (geometry, layer
// and content scale jump while invisible) -> fade_in (new look fades in).
// Driven by SetTimer with a TIMERPROC on this thread's message loop; there are
// no native-to-Dart calls, so nothing here can outlive the engine.
constexpr DWORD kFadeOutMs = 140;
constexpr DWORD kFadeInMs = 220;
constexpr UINT kFadeTimerIntervalMs = 16;  // ~60 fps

struct AlphaFade {
  HWND hwnd = nullptr;
  double from = 1.0;
  double to = 1.0;
  DWORD duration_ms = 1;
  DWORD start_tick = 0;
  UINT_PTR timer_id = 0;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
};

std::unique_ptr<AlphaFade> g_fade;

double CurrentAlpha(HWND hwnd, double fallback) {
  DWORD flags = 0;
  BYTE alpha = 255;
  COLORREF key = 0;
  if (!GetLayeredWindowAttributes(hwnd, &key, &alpha, &flags)) return fallback;
  return static_cast<double>(alpha) / 255.0;
}

void SetAlphaNow(HWND hwnd, double alpha) {
  const double clamped = alpha < 0.0 ? 0.0 : (alpha > 1.0 ? 1.0 : alpha);
  SetLayeredWindowAttributes(hwnd, 0, static_cast<BYTE>(clamped * 255 + 0.5),
                             LWA_ALPHA);
}

// Stops any running fade. A pending MethodResult is dropped without a reply:
// Dart wraps every fade call in a timeout, so a silent drop cannot hang the
// bar. configure() also cancels, so a plain reconfigure always wins over a
// still-running fade.
void CancelAlphaFade() {
  if (g_fade == nullptr) return;
  if (g_fade->timer_id != 0) KillTimer(nullptr, g_fade->timer_id);
  g_fade.reset();
}

// Respect the system "Show animations in Windows" setting: when animations are
// off, apply the final alpha directly instead of fading.
bool SystemAnimationsDisabled() {
  BOOL enabled = TRUE;
  SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &enabled, 0);
  return !enabled;
}

void CALLBACK AlphaFadeProc(HWND, UINT, UINT_PTR timer_id, DWORD) {
  if (g_fade == nullptr || g_fade->timer_id != timer_id) {
    KillTimer(nullptr, timer_id);
    return;
  }
  if (!IsWindow(g_fade->hwnd)) {
    // Bar closed mid-fade: drop everything (the Dart side has timed out).
    CancelAlphaFade();
    return;
  }
  const DWORD elapsed = GetTickCount() - g_fade->start_tick;
  double t = g_fade->duration_ms == 0
                 ? 1.0
                 : static_cast<double>(elapsed) / g_fade->duration_ms;
  if (t > 1.0) t = 1.0;
  const double eased = t * t * (3.0 - 2.0 * t);  // smoothstep easing
  SetAlphaNow(g_fade->hwnd, g_fade->from + (g_fade->to - g_fade->from) * eased);
  if (t >= 1.0) {
    auto result = std::move(g_fade->result);
    CancelAlphaFade();
    if (result != nullptr) result->Success();
  }
}

void StartAlphaFade(
    HWND hwnd, double to, DWORD duration_ms, double from_fallback,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (g_fade != nullptr && IsWindow(g_fade->hwnd)) {
    result->Error("BUSY", "another fade is still running");
    return;
  }
  CancelAlphaFade();  // stale state from a destroyed window
  if (!IsWindow(hwnd)) {
    result->Error("INVALID_WINDOW", "bar window is gone");
    return;
  }
  if (SystemAnimationsDisabled()) {
    SetAlphaNow(hwnd, to);
    result->Success();
    return;
  }
  auto fade = std::make_unique<AlphaFade>();
  fade->hwnd = hwnd;
  fade->from = CurrentAlpha(hwnd, from_fallback);
  fade->to = to;
  fade->duration_ms = duration_ms;
  fade->start_tick = GetTickCount();
  const UINT_PTR timer_id =
      SetTimer(nullptr, 0, kFadeTimerIntervalMs, AlphaFadeProc);
  if (timer_id == 0) {
    // Timer creation failed: degrade to an instant switch.
    SetAlphaNow(hwnd, to);
    result->Success();
    return;
  }
  fade->timer_id = timer_id;
  fade->result = std::move(result);
  g_fade = std::move(fade);
}

void HandleFadeOut(
    HWND hwnd,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Fallback 0.92 = the default appearance opacity (attributes query failing
  // is rare and only shifts the perceived start brightness slightly).
  StartAlphaFade(hwnd, 0.0, kFadeOutMs, 0.92, std::move(result));
}

void HandleFadeIn(
    HWND hwnd, const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const double target = GetDouble(args, "opacity", 0.92);
  StartAlphaFade(hwnd, target, kFadeInMs, 0.0, std::move(result));
}

// Applies the desktop schedule capsule look: frameless, no taskbar button,
// layered (opacity + optional click-through), clipped into a capsule and
// centered horizontally near the top/upper-middle/bottom of the work area.
//
// A full-width docked bar covered the desktop shortcuts on the left; a centered
// capsule leaves them visible.
void ConfigureWindow(HWND hwnd, const flutter::EncodableMap& args) {
  // A plain configure always wins over a still-running fade: settings edits
  // must never leave the window at a stale alpha.
  CancelAlphaFade();

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
        if (call.method_name() == "get_foreground") {
          // Dual-appearance probe: the bar's Dart side polls this once per
          // payload tick and picks the desktop/foreground look accordingly.
          result->Success(
              flutter::EncodableValue(IsProgramInForeground(hwnd)));
          return;
        }
        if (call.method_name() == "fade_out") {
          HandleFadeOut(hwnd, std::move(result));
          return;
        }
        if (call.method_name() == "fade_in") {
          const auto* args = std::get_if<flutter::EncodableMap>(
              call.arguments());
          HandleFadeIn(hwnd, args == nullptr ? flutter::EncodableMap{}
                                             : *args,
                       std::move(result));
          return;
        }
        if (call.method_name() == "close") {
          CancelAlphaFade();
          PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  g_channels.push_back(std::move(channel));
}
