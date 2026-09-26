#include "desktop_ball_window.h"

#include <windowsx.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <string>

#include "desktop_bar_channel.h"
#include "window_menu.h"

namespace {

constexpr char kChannelName[] = "class_score/desktop_ball_window";
constexpr wchar_t kBallWindowClass[] = L"CLASS_SCORE_DESKTOP_BALL_WINDOW";

constexpr UINT kMenuShow = 1;
constexpr UINT kMenuHide = 2;
constexpr UINT kMenuQuit = 3;

// While stuck to the capsule the ball re-reads the capsule rect on a timer:
// Dart's configure calls are deduplicated, but the capsule can move (position
// setting, foreground appearance, narrow-screen clamp) without a new push.
// 200 ms keeps the pair visually glued during the desktop <-> foreground
// cross-fade without any measurable cost (one GetWindowRect per tick).
constexpr UINT_PTR kFollowTimerId = 1;
constexpr UINT kFollowTimerMs = 200;

// Transparent padding around the painted circle: it absorbs the anti-aliased
// edge and gives hover room. The padding never changes the window size on
// hover (that would make the ball jump away from under the cursor).
constexpr double kPaddingLogical = 4.0;
constexpr double kHoverGrowLogical = 2.0;
// A press only turns into a drag after moving this far (physical pixels).
constexpr LONG kDragThresholdPx = 4;

enum class BallMode { kBesideBar, kCorner };

// Geometry of the last placement; also the input for every repaint.
struct BallGeometry {
  RECT rect{};
  LONG diameter = 0;
  double alpha = 0.92;
  bool topmost = false;
};

struct BallState {
  // Whether Dart wants the ball shown (the feature toggle); independent of
  // whether the window is currently visible on screen.
  bool enabled = false;
  BallMode mode = BallMode::kCorner;
  double capsule_height = 52.0;
  double gap = 12.0;
  double margin = 16.0;
  double offset_x = 0.0;
  double offset_y = 0.0;
  std::string layer = "desktop";
  double opacity = 0.92;
  // Fallback only: Dart always pushes DesktopBarPalette.barBackground, the same
  // colour the capsule is filled with.
  COLORREF color = RGB(0x14, 0x1a, 0x24);
  bool hover = false;
  bool press = false;
  bool drag_started = false;
  POINT press_screen{};
  RECT press_rect{};
  BallGeometry geometry{};
};

BallState g_state;
HWND g_ball = nullptr;
HWND g_main = nullptr;

// Keeps the method channel alive: the engine only holds a raw pointer to the
// handler, so the channel object must outlive the engine.
std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

double Clamp(double value, double low, double high) {
  if (value < low) return low;
  if (value > high) return high;
  return value;
}

const flutter::EncodableValue* Find(const flutter::EncodableMap& args,
                                    const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return nullptr;
  return &it->second;
}

double GetDouble(const flutter::EncodableMap& args, const char* key,
                 double fallback) {
  const auto* value = Find(args, key);
  if (value == nullptr) return fallback;
  if (auto* as_double = std::get_if<double>(value)) return *as_double;
  if (auto* as_int = std::get_if<int32_t>(value)) {
    return static_cast<double>(*as_int);
  }
  if (auto* as_long = std::get_if<int64_t>(value)) {
    return static_cast<double>(*as_long);
  }
  return fallback;
}

bool GetBool(const flutter::EncodableMap& args, const char* key,
             bool fallback) {
  const auto* value = Find(args, key);
  if (value == nullptr) return fallback;
  if (auto* as_bool = std::get_if<bool>(value)) return *as_bool;
  return fallback;
}

std::string GetString(const flutter::EncodableMap& args, const char* key,
                      const char* fallback) {
  const auto* value = Find(args, key);
  if (value == nullptr) return fallback;
  if (auto* as_string = std::get_if<std::string>(value)) return *as_string;
  return fallback;
}

int64_t GetInt(const flutter::EncodableMap& args, const char* key,
               int64_t fallback) {
  const auto* value = Find(args, key);
  if (value == nullptr) return fallback;
  if (auto* as_long = std::get_if<int64_t>(value)) return *as_long;
  if (auto* as_int = std::get_if<int32_t>(value)) return *as_int;
  return fallback;
}

UINT DpiOf(HWND hwnd) {
  const UINT dpi = GetDpiForWindow(hwnd);
  return dpi == 0 ? 96 : dpi;
}

LONG ToPhysical(UINT dpi, double logical) {
  const double scale = static_cast<double>(dpi) / 96.0;
  return static_cast<LONG>(logical * scale + 0.5);
}

double ToLogical(UINT dpi, LONG physical) {
  const double scale = static_cast<double>(dpi) / 96.0;
  return static_cast<double>(physical) / scale;
}

COLORREF BlendColor(COLORREF from, COLORREF to, double t) {
  const double u = Clamp(t, 0.0, 1.0);
  const auto red = static_cast<BYTE>(
      GetRValue(from) * (1.0 - u) + GetRValue(to) * u + 0.5);
  const auto green = static_cast<BYTE>(
      GetGValue(from) * (1.0 - u) + GetGValue(to) * u + 0.5);
  const auto blue = static_cast<BYTE>(
      GetBValue(from) * (1.0 - u) + GetBValue(to) * u + 0.5);
  return RGB(red, green, blue);
}

// Where the ball should be, in physical pixels.
//
// Beside the capsule everything is derived from the capsule's real window rect
// (its own DPI included), so the pair stays centred exactly as the capsule's
// native configure computes it - the two windows never disagree on maths.
bool ComputeGeometry(BallGeometry* out) {
  out->topmost = false;
  out->alpha = g_state.opacity;
  out->diameter = 0;

  if (g_state.mode == BallMode::kBesideBar) {
    HWND bar = GetDesktopBarWindow();
    RECT bar_rect{};
    if (bar != nullptr && IsWindowVisible(bar) &&
        GetWindowRect(bar, &bar_rect)) {
      // Same height as the capsule, by definition: the ball is diameter =
      // capsule height, so the two read as one widget glued together. Taking it
      // from the capsule's real rect (not from the setting) keeps them equal
      // even during the desktop <-> foreground cross-fade, when the capsule is
      // still drawn at the old scale for a moment.
      const LONG bar_height = bar_rect.bottom - bar_rect.top;
      const UINT dpi = DpiOf(bar);
      LONG diameter = bar_height;
      if (diameter <= 0) diameter = 1;
      const LONG padding = ToPhysical(dpi, kPaddingLogical);
      const LONG gap = ToPhysical(dpi, g_state.gap);
      const LONG width = diameter + 2 * padding;

      out->diameter = diameter;
      out->rect.left = bar_rect.right + gap - padding;
      out->rect.right = out->rect.left + width;
      out->rect.top = bar_rect.top + (bar_height - width) / 2;
      out->rect.bottom = out->rect.top + width;

      // Mirror the capsule's z-order and opacity: when the capsule switches to
      // the foreground look (top-most, other opacity), the ball follows so the
      // pair never breaks apart.
      out->topmost =
          (GetWindowLongPtr(bar, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
      DWORD flags = 0;
      BYTE alpha = 255;
      COLORREF key = 0;
      if (GetLayeredWindowAttributes(bar, &key, &alpha, &flags)) {
        out->alpha = alpha / 255.0;
      }
      return true;
    }
    // Capsule not on screen yet (first-frame race, or closed by hand): park at
    // the corner; the follow timer puts it back once the capsule shows up.
  }

  HWND anchor = g_ball != nullptr ? g_ball : g_main;
  if (anchor == nullptr) return false;

  const RECT work = GetDesktopWorkArea(anchor);
  const UINT dpi = DpiOf(anchor);
  const LONG margin = ToPhysical(dpi, g_state.margin);
  const LONG padding = ToPhysical(dpi, kPaddingLogical);
  // Same diameter the capsule-anchored branch uses (see above): the ball is
  // always exactly as tall as the capsule, so the capsule height is the only
  // input it needs. There is no separate ball size setting any more.
  const LONG diameter = ToPhysical(dpi, g_state.capsule_height);
  if (diameter <= 0) return false;
  const LONG width = diameter + 2 * padding;

  // Offsets are deltas from the default spot (top-right corner, margin away),
  // x towards the right, y downwards - the same definition the drag handler
  // reports back, so a saved position always replays exactly. The margin is
  // measured to the *painted* circle's edge, so the transparent padding around
  // it does not eat into the gap the user sees.
  const LONG visual_right =
      work.right - margin + ToPhysical(dpi, g_state.offset_x);
  const LONG visual_top =
      work.top + margin + ToPhysical(dpi, g_state.offset_y);
  LONG left = visual_right - diameter - padding;
  LONG top = visual_top - padding;
  if (left < work.left) left = work.left;
  if (top < work.top) top = work.top;
  if (left + width > work.right) left = work.right - width;
  if (top + width > work.bottom) top = work.bottom - width;

  out->diameter = diameter;
  out->rect = RECT{left, top, left + width, top + width};
  out->topmost = g_state.layer == "topMost";
  out->alpha = g_state.opacity;
  return true;
}

// The ball's glyph: the Material **school** icon (graduation cap + tassel),
// filled 24x24 variant. Its path data is
//   M5 13.18v4L12 21l7-3.82v-4L12 17l-7-3.82zM12 3L1 9l11 6l9-4.91V17h2V9L12 3z
// and every segment of it is a straight line, so the icon is two polygons
// here - no SVG parser, no font and no bitmap asset:
//   * the MaterialIcons font Flutter ships in `data/flutter_assets` is
//     tree-shaken down to the icons the Dart code actually uses, so a
//     codepoint lookup could silently disappear the day that usage changes;
//   * a bitmap asset would need one file per DPI to stay crisp.
// The coordinates below are the path's own 24x24 units (ink spans y 3..21 and
// x 1..23, i.e. it is centred in its box).
constexpr int kGlyphShapeCount = 2;
constexpr int kGlyphPointCount[kGlyphShapeCount] = {6, 7};
constexpr double kGlyphShape[kGlyphShapeCount][7][2] = {
    // The band under the mortarboard.
    {{5.0, 13.18},
     {5.0, 17.18},
     {12.0, 21.0},
     {19.0, 17.18},
     {19.0, 13.18},
     {12.0, 17.0}},
    // The mortarboard plus the tassel hanging off its right corner.
    {{12.0, 3.0},
     {1.0, 9.0},
     {12.0, 15.0},
     {21.0, 10.09},
     {21.0, 17.0},
     {23.0, 17.0},
     {23.0, 9.0}},
};

// True when (x, y) - in glyph units - is inside the icon.
//
// Winding number rather than a bounding-box guess: the two polygons are
// disjoint, so any winding count other than zero means "inside". The y
// comparisons are half-open (<= on the first edge, > on the second) so a
// corner vertex shared by two edges is crossed exactly once and stays solid.
bool InsideGlyph(double x, double y) {
  int winding = 0;
  for (int shape = 0; shape < kGlyphShapeCount; ++shape) {
    const int count = kGlyphPointCount[shape];
    for (int index = 0; index < count; ++index) {
      const int next = (index + 1) % count;
      const double x0 = kGlyphShape[shape][index][0];
      const double y0 = kGlyphShape[shape][index][1];
      const double x1 = kGlyphShape[shape][next][0];
      const double y1 = kGlyphShape[shape][next][1];
      const double side = (x1 - x0) * (y - y0) - (x - x0) * (y1 - y0);
      if (y0 <= y) {
        if (y1 > y && side > 0.0) ++winding;
      } else if (y1 <= y && side < 0.0) {
        --winding;
      }
    }
  }
  return winding != 0;
}

// Paints the icon centred in the already-filled circle.
//
// The icon is rasterised from the polygons above with 4x4 supersampling per
// pixel: GDI has no anti-aliasing for filled shapes, and for a single glyph
// per-pixel coverage is both shorter and sharper than pulling a whole drawing
// stack in for one icon. Only the RGB channels are written - the icon always
// stays inside the opaque part of the circle (its box diagonal is shorter than
// the diameter) and the edge's own coverage is already in the alpha channel, so
// blending over the existing pixels is exact and cannot punch a hole in the
// ball. The icon is white, matching the capsule's text on its dark fill.
void DrawGlyph(unsigned char* pixels, int width, int height, double radius) {
  constexpr int kSamples = 4;
  constexpr int kSamplesTotal = kSamples * kSamples;
  constexpr double kGlyphRgb = 255.0;
  if (pixels == nullptr || radius <= 0.0) return;

  // Material icons keep ~2/24 of padding inside their box, so a box of
  // 1.15 x radius lands the ink at about half the diameter - the optical size
  // Flutter uses for a 24px icon in a 48-52px container.
  const double box = radius * 1.15;
  const double scale = box / 24.0;
  const double origin_x = width / 2.0 - box / 2.0;
  const double origin_y = height / 2.0 - box / 2.0;

  const int left = std::max(0, static_cast<int>(std::floor(origin_x)));
  const int top = std::max(0, static_cast<int>(std::floor(origin_y)));
  const int right =
      std::min(width, static_cast<int>(std::ceil(origin_x + box)) + 1);
  const int bottom =
      std::min(height, static_cast<int>(std::ceil(origin_y + box)) + 1);

  for (int y = top; y < bottom; ++y) {
    for (int x = left; x < right; ++x) {
      int hits = 0;
      for (int sample_y = 0; sample_y < kSamples; ++sample_y) {
        for (int sample_x = 0; sample_x < kSamples; ++sample_x) {
          const double px = x + (sample_x + 0.5) / kSamples;
          const double py = y + (sample_y + 0.5) / kSamples;
          if (InsideGlyph((px - origin_x) / scale, (py - origin_y) / scale)) {
            ++hits;
          }
        }
      }
      if (hits == 0) continue;

      const double cover = static_cast<double>(hits) / kSamplesTotal;
      unsigned char* pixel = pixels + (static_cast<size_t>(y) * width + x) * 4;
      for (int channel = 0; channel < 3; ++channel) {
        pixel[channel] = static_cast<unsigned char>(
            kGlyphRgb * cover + pixel[channel] * (1.0 - cover) + 0.5);
      }
    }
  }
}

LRESULT CALLBACK BallWndProc(HWND hwnd, UINT message, WPARAM wparam,
                             LPARAM lparam);

// Renders the ball into a premultiplied 32bpp DIB and pushes it with
// UpdateLayeredWindow. Per-pixel alpha gives a smooth anti-aliased edge (the
// capsule gets away with a 1-bit window region because it is huge; a 40px
// circle would look like a staircase).
void Paint() {
  if (g_ball == nullptr) return;

  RECT client{};
  if (!GetClientRect(g_ball, &client)) return;
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0) return;

  const double radius = g_state.geometry.diameter / 2.0 +
                        (g_state.hover ? kHoverGrowLogical *
                                             static_cast<double>(DpiOf(g_ball)) /
                                             96.0
                                       : 0.0);
  if (radius <= 0.0) return;

  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;  // top-down
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HDC mem = CreateCompatibleDC(nullptr);
  if (mem == nullptr) return;
  HBITMAP bitmap =
      CreateDIBSection(mem, &bitmap_info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bitmap == nullptr || bits == nullptr) {
    if (bitmap != nullptr) DeleteObject(bitmap);
    DeleteDC(mem);
    return;
  }
  HGDIOBJ old_bitmap = SelectObject(mem, bitmap);
  ZeroMemory(bits, static_cast<size_t>(width) * static_cast<size_t>(height) *
                       sizeof(DWORD));

  const double center_x = width / 2.0;
  const double center_y = height / 2.0;
  // One flat colour - the very one the capsule's normal bar uses (Dart passes
  // DesktopBarPalette.barBackground): the ball reads as part of the capsule, so
  // a gradient of its own would break the match. Hover only lifts the fill a
  // touch, which is feedback enough without becoming a second colour.
  const COLORREF fill_color =
      g_state.hover ? BlendColor(g_state.color, RGB(255, 255, 255), 0.10)
                    : g_state.color;

  auto* pixel = static_cast<unsigned char*>(bits);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x, pixel += 4) {
      const double dx = x + 0.5 - center_x;
      const double dy = y + 0.5 - center_y;
      const double distance = std::sqrt(dx * dx + dy * dy);
      double cover = radius + 0.5 - distance;
      if (cover <= 0.0) continue;
      if (cover > 1.0) cover = 1.0;

      COLORREF base = fill_color;
      // The capsule draws a 1px 15%-white border (DesktopBarPalette
      // .capsuleBorder); the ball repeats it, ramped over 1.5px so the curve of
      // a small circle does not show a staircase where the border starts.
      double border = (distance - (radius - 1.5)) / 1.5;
      if (border > 0.0) {
        if (border > 1.0) border = 1.0;
        base = BlendColor(base, RGB(255, 255, 255), 0.15 * border);
      }
      // UpdateLayeredWindow takes premultiplied BGRA, so byte 0 is blue (not
      // the red GetRValue names - a swap here silently recolours the ball).
      pixel[0] = static_cast<unsigned char>(GetBValue(base) * cover + 0.5);
      pixel[1] = static_cast<unsigned char>(GetGValue(base) * cover + 0.5);
      pixel[2] = static_cast<unsigned char>(GetRValue(base) * cover + 0.5);
      pixel[3] = static_cast<unsigned char>(cover * 255.0 + 0.5);
    }
  }

  DrawGlyph(static_cast<unsigned char*>(bits), width, height, radius);

  POINT source{0, 0};
  POINT dest{g_state.geometry.rect.left, g_state.geometry.rect.top};
  SIZE size{width, height};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.BlendFlags = 0;
  blend.SourceConstantAlpha = static_cast<BYTE>(
      Clamp(g_state.geometry.alpha, 0.0, 1.0) * 255.0 + 0.5);
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(g_ball, nullptr, &dest, &size, mem, &source, 0, &blend,
                      ULW_ALPHA);

  SelectObject(mem, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(mem);
}

void SendToDart(const char* method,
                std::unique_ptr<flutter::EncodableValue> arguments) {
  if (g_channel == nullptr) return;
  g_channel->InvokeMethod(method, std::move(arguments), nullptr);
}

void SendCommand(const char* command) {
  SendToDart("on_command",
             std::make_unique<flutter::EncodableValue>(std::string(command)));
}

void SendClick() { SendToDart("on_click", nullptr); }

// Reports the position the ball was dropped at, as an offset from the default
// corner spot (x rightwards, y downwards) - the exact values the corner
// placement adds back, so a drag is replayed on the next launch.
void SendMoved() {
  if (g_ball == nullptr) return;
  const RECT work = GetDesktopWorkArea(g_ball);
  const UINT dpi = DpiOf(g_ball);
  const LONG margin = ToPhysical(dpi, g_state.margin);
  const LONG padding = ToPhysical(dpi, kPaddingLogical);
  const LONG diameter = ToPhysical(dpi, g_state.capsule_height);
  // Mirror of ComputeGeometry's corner placement: the default spot measures the
  // margin to the painted circle, not to the transparent padded window.
  const LONG default_left = work.right - margin - diameter - padding;
  const LONG default_top = work.top + margin - padding;
  const RECT& rect = g_state.geometry.rect;

  const double offset_x = ToLogical(dpi, rect.left - default_left);
  const double offset_y = ToLogical(dpi, rect.top - default_top);

  flutter::EncodableMap args{
      {flutter::EncodableValue("offset_x"),
       flutter::EncodableValue(offset_x)},
      {flutter::EncodableValue("offset_y"),
       flutter::EncodableValue(offset_y)},
  };
  SendToDart("on_moved",
             std::make_unique<flutter::EncodableValue>(std::move(args)));
}

// Shows / hides / moves / re-stacks the ball according to the current state.
void ApplyPlacement() {
  if (g_ball == nullptr) return;
  const RECT& rect = g_state.geometry.rect;
  const LONG width = rect.right - rect.left;
  const LONG height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) return;

  const bool want_topmost = g_state.geometry.topmost;
  const bool is_topmost =
      (GetWindowLongPtr(g_ball, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
  if (want_topmost != is_topmost) {
    // HWND_BOTTOM alone does not leave the top-most band: Windows needs an
    // explicit HWND_NOTOPMOST first, otherwise the ball stays pinned above
    // everything while claiming to be "desktop level".
    SetWindowPos(g_ball, want_topmost ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0,
                 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }

  SetWindowPos(g_ball, want_topmost ? HWND_TOPMOST : HWND_BOTTOM, rect.left,
               rect.top, width, height,
               SWP_NOACTIVATE |
                   (g_state.enabled ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));

  if (!g_state.enabled) {
    KillTimer(g_ball, kFollowTimerId);
    return;
  }
  Paint();
  if (g_state.mode == BallMode::kBesideBar) {
    SetTimer(g_ball, kFollowTimerId, kFollowTimerMs, nullptr);
  } else {
    KillTimer(g_ball, kFollowTimerId);
  }
}

bool IsInsideBall(POINT client) {
  if (g_ball == nullptr || g_state.geometry.diameter <= 0) return false;
  const RECT& rect = g_state.geometry.rect;
  const LONG width = rect.right - rect.left;
  const LONG height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) return false;
  // Test against the *hovered* radius: the cursor then sits inside the ring
  // that gets painted while hovering, so hover cannot flicker.
  const double scale = static_cast<double>(DpiOf(g_ball)) / 96.0;
  const double radius =
      g_state.geometry.diameter / 2.0 + kHoverGrowLogical * scale;
  const double dx = client.x + 0.5 - width / 2.0;
  const double dy = client.y + 0.5 - height / 2.0;
  return dx * dx + dy * dy <= radius * radius;
}

// Corner mode only: keeps the ball glued to the cursor (clamped to the work
// area). Beside the capsule the position is derived, so a press there is
// always just a click.
void DragTo(POINT client) {
  if (g_ball == nullptr || g_state.mode != BallMode::kCorner) return;

  POINT screen = client;
  ClientToScreen(g_ball, &screen);
  if (!g_state.drag_started) {
    const LONG dx = screen.x - g_state.press_screen.x;
    const LONG dy = screen.y - g_state.press_screen.y;
    if (dx * dx + dy * dy <= kDragThresholdPx * kDragThresholdPx) return;
    g_state.drag_started = true;
  }

  RECT rect = g_state.press_rect;
  rect.left += screen.x - g_state.press_screen.x;
  rect.right += screen.x - g_state.press_screen.x;
  rect.top += screen.y - g_state.press_screen.y;
  rect.bottom += screen.y - g_state.press_screen.y;

  // Never let a drag leave the work area: a ball parked off-screen looks lost.
  const RECT work = GetDesktopWorkArea(g_ball);
  if (rect.left < work.left) {
    rect.right += work.left - rect.left;
    rect.left = work.left;
  }
  if (rect.top < work.top) {
    rect.bottom += work.top - rect.top;
    rect.top = work.top;
  }
  if (rect.right > work.right) {
    rect.left -= rect.right - work.right;
    rect.right = work.right;
  }
  if (rect.bottom > work.bottom) {
    rect.top -= rect.bottom - work.bottom;
    rect.bottom = work.bottom;
  }

  SetWindowPos(g_ball, nullptr, rect.left, rect.top, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  g_state.geometry.rect = rect;
}

// Creates the ball window on demand: with the feature switched off the window
// never exists, which is why it is built here instead of at startup.
bool EnsureWindow() {
  if (g_ball != nullptr) return true;

  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(WNDCLASSEXW);
  window_class.lpfnWndProc = BallWndProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.hCursor = LoadCursorW(nullptr, IDC_HAND);
  window_class.lpszClassName = kBallWindowClass;
  if (RegisterClassExW(&window_class) == 0 &&
      GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return false;
  }

  HWND window =
      CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                      kBallWindowClass, L"class_score_ball", WS_POPUP, 0, 0, 10,
                      10, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (window == nullptr) return false;
  g_ball = window;
  return true;
}

LRESULT CALLBACK BallWndProc(HWND hwnd, UINT message, WPARAM wparam,
                             LPARAM lparam) {
  switch (message) {
    case WM_NCHITTEST: {
      POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(hwnd, &pt);
      // Outside the circle nothing belongs to the ball: the transparent ring
      // must stay usable (desktop icons, other windows, ...).
      return IsInsideBall(pt) ? HTCLIENT : HTTRANSPARENT;
    }

    case WM_MOUSEMOVE: {
      const POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (g_state.press) {
        DragTo(pt);
        return 0;
      }
      if (!g_state.hover) {
        g_state.hover = true;
        Paint();
      }
      TRACKMOUSEEVENT track{};
      track.cbSize = sizeof(TRACKMOUSEEVENT);
      track.dwFlags = TME_LEAVE;
      track.hwndTrack = hwnd;
      TrackMouseEvent(&track);
      return 0;
    }

    case WM_MOUSELEAVE:
      if (g_state.hover) {
        g_state.hover = false;
        Paint();
      }
      return 0;

    case WM_LBUTTONDOWN:
      g_state.press = true;
      g_state.drag_started = false;
      GetCursorPos(&g_state.press_screen);
      g_state.press_rect = g_state.geometry.rect;
      SetCapture(hwnd);
      return 0;

    case WM_LBUTTONUP: {
      if (!g_state.press) return 0;
      if (GetCapture() == hwnd) ReleaseCapture();
      const bool dragged = g_state.drag_started;
      g_state.press = false;
      g_state.drag_started = false;
      if (dragged) {
        SendMoved();
      } else {
        SendClick();
      }
      return 0;
    }

    case WM_RBUTTONUP: {
      POINT pt{};
      GetCursorPos(&pt);
      const UINT command = ShowWindowMenu(
          hwnd,
          {{kMenuShow, L"显示主窗口"},
           {kMenuHide, L"隐藏主窗口"},
           {0, nullptr},
           {kMenuQuit, L"退出程序"}},
          pt);
      if (command == kMenuShow) {
        SendCommand("show");
      } else if (command == kMenuHide) {
        SendCommand("hide");
      } else if (command == kMenuQuit) {
        SendCommand("quit");
      }
      return 0;
    }

    case WM_SETCURSOR:
      SetCursor(LoadCursorW(nullptr, IDC_HAND));
      return TRUE;

    case WM_ERASEBKGND:
      // Everything is composited through UpdateLayeredWindow; there is no
      // regular paint cycle to service.
      return 1;

    case WM_TIMER:
      if (wparam == kFollowTimerId) {
        // The capsule can move on its own (position setting, foreground look,
        // narrow-screen clamp) while Dart's pushes stay deduplicated.
        if (g_state.enabled && g_state.mode == BallMode::kBesideBar) {
          BallGeometry next{};
          if (ComputeGeometry(&next) &&
              (!EqualRect(&next.rect, &g_state.geometry.rect) ||
               next.diameter != g_state.geometry.diameter ||
               next.topmost != g_state.geometry.topmost ||
               next.alpha != g_state.geometry.alpha)) {
            g_state.geometry = next;
            ApplyPlacement();
          }
        }
        return 0;
      }
      break;

    case WM_DESTROY:
      KillTimer(hwnd, kFollowTimerId);
      g_ball = nullptr;
      return 0;
  }

  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// Applies every appearance field from Dart and (re)places the ball.
void HandleConfigure(const flutter::EncodableMap& args) {
  g_state.mode = GetString(args, "mode", "corner") == "beside"
                     ? BallMode::kBesideBar
                     : BallMode::kCorner;
  g_state.capsule_height = GetDouble(args, "capsule_height", 52.0);
  g_state.gap = GetDouble(args, "gap", 12.0);
  g_state.margin = GetDouble(args, "margin", 16.0);
  g_state.offset_x = GetDouble(args, "offset_x", 0.0);
  g_state.offset_y = GetDouble(args, "offset_y", 0.0);
  g_state.layer = GetString(args, "layer", "desktop");
  g_state.opacity = Clamp(GetDouble(args, "opacity", 0.92), 0.0, 1.0);

  const int64_t argb = GetInt(args, "color", 0xFF141A24);
  g_state.color = RGB(static_cast<BYTE>((argb >> 16) & 0xFF),
                      static_cast<BYTE>((argb >> 8) & 0xFF),
                      static_cast<BYTE>(argb & 0xFF));
  g_state.enabled = GetBool(args, "enabled", false);

  if (!g_state.enabled) {
    if (g_ball != nullptr) {
      ShowWindow(g_ball, SW_HIDE);
      KillTimer(g_ball, kFollowTimerId);
    }
    return;
  }
  if (!EnsureWindow()) return;

  BallGeometry geometry{};
  if (!ComputeGeometry(&geometry)) return;
  g_state.geometry = geometry;
  ApplyPlacement();
}

void DestroyBall() {
  if (g_ball != nullptr) {
    KillTimer(g_ball, kFollowTimerId);
    // WM_DESTROY clears g_ball.
    DestroyWindow(g_ball);
  }
  g_state = BallState{};
}

}  // namespace

void RegisterDesktopBallChannel(flutter::FlutterViewController* view_controller,
                                HWND main_window) {
  if (view_controller == nullptr || view_controller->engine() == nullptr) {
    return;
  }

  g_main = main_window;
  g_channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          view_controller->engine()->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "configure") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("INVALID_ARGUMENTS", "configure expects a map");
            return;
          }
          HandleConfigure(*args);
          result->Success();
          return;
        }
        if (call.method_name() == "close") {
          DestroyBall();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
}

void DestroyDesktopBallWindow() { DestroyBall(); }
