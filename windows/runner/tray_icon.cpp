#include "tray_icon.h"

#include <shellapi.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#include "app_quit.h"
#include "resource.h"
#include "window_menu.h"

namespace {

constexpr char kChannelName[] = "class_score/tray";
constexpr UINT kTrayIconId = 1;

constexpr UINT kMenuShow = 1;
constexpr UINT kMenuHide = 2;
constexpr UINT kMenuQuit = 3;

// Keeps the method channel alive: the engine only holds a raw pointer to the
// handler, so the channel object must outlive the engine.
std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

HWND g_main_window = nullptr;
bool g_icon_added = false;
UINT g_taskbar_created_message = 0;
std::wstring g_tooltip = L"班级量化评分（后台运行中）";

bool GetBool(const flutter::EncodableMap* args, const char* key,
             bool fallback) {
  if (args == nullptr) return fallback;
  auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return fallback;
  if (auto* value = std::get_if<bool>(&it->second)) return *value;
  return fallback;
}

// Small tray icon (SM_CXSMICON), loaded from the exe's own resource with
// LR_SHARED so it needs no manual DestroyIcon.
HICON LoadTrayIcon() {
  const int size = GetSystemMetrics(SM_CXSMICON);
  auto icon = static_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr),
                                            MAKEINTRESOURCEW(IDI_APP_ICON),
                                            IMAGE_ICON, size, size, LR_SHARED));
  if (icon == nullptr) icon = LoadIconW(nullptr, IDI_APPLICATION);
  return icon;
}

void AddTrayIcon() {
  if (g_main_window == nullptr) return;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(NOTIFYICONDATAW);
  data.hWnd = g_main_window;
  data.uID = kTrayIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayCallbackMessage;
  data.hIcon = LoadTrayIcon();
  wcsncpy_s(data.szTip, g_tooltip.c_str(), _TRUNCATE);
  g_icon_added = Shell_NotifyIconW(g_icon_added ? NIM_MODIFY : NIM_ADD, &data) !=
                 FALSE;
}

void SendCommand(const char* command) {
  if (g_channel == nullptr) return;
  g_channel->InvokeMethod(
      "on_command",
      std::make_unique<flutter::EncodableValue>(std::string(command)),
      nullptr);
}

void HandleTrayCallback(UINT event) {
  switch (event) {
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      // Single click restores the window: the ball and the tray are the two
      // ways back to the app once the main window is hidden.
      SendCommand("show");
      return;
    case WM_RBUTTONUP: {
      POINT pt{};
      GetCursorPos(&pt);
      const UINT command = ShowWindowMenu(
          g_main_window,
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
        // 退出不绕 Dart：绕一趟要等 Dart 发回关闭指令，再等各引擎收尾，
        // 实测要 5.8 秒进程才消失（见 app_quit.h）。
        QuitApplicationNow();
      }
      return;
    }
    default:
      return;
  }
}

}  // namespace

void RegisterTrayChannel(flutter::FlutterViewController* view_controller,
                         HWND main_window) {
  if (view_controller == nullptr || view_controller->engine() == nullptr) {
    return;
  }

  g_main_window = main_window;
  // Registered message: Windows allocates a fresh id for it, which is how the
  // shell announces "explorer restarted, recreate your icons".
  g_taskbar_created_message = RegisterWindowMessageW(L"TaskbarCreated");

  g_channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          view_controller->engine()->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "set_enabled") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (GetBool(args, "enabled", false)) {
            AddTrayIcon();
          } else {
            RemoveTrayIcon();
          }
          result->Success();
          return;
        }
        if (call.method_name() == "quit_now") {
          // Dart 侧的「关闭窗口即退出」走这里。先回执再动手：调用方不需要真的
          // 等到进程结束，反正下一步进程就没了。
          result->Success();
          QuitApplicationNow();
          return;
        }
        if (call.method_name() == "show_balloon") {
          if (!g_icon_added) {
            // Nothing to attach it to; the hint is one-off and must never
            // break close-to-tray.
            result->Success();
            return;
          }
          NOTIFYICONDATAW data{};
          data.cbSize = sizeof(NOTIFYICONDATAW);
          data.hWnd = g_main_window;
          data.uID = kTrayIconId;
          data.uFlags = NIF_INFO;
          wcsncpy_s(data.szInfoTitle, L"已最小化到托盘", _TRUNCATE);
          wcsncpy_s(data.szInfo,
                    L"程序仍在后台运行，桌面课表与悬浮球保持显示；右键托盘图标可退出",
                    _TRUNCATE);
          data.dwInfoFlags = NIIF_INFO;
          Shell_NotifyIconW(NIM_MODIFY, &data);
          result->Success();
          return;
        }
        result->NotImplemented();
      });
}

bool HandleTrayMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  (void)hwnd;
  (void)wparam;

  if (g_taskbar_created_message != 0 && message == g_taskbar_created_message) {
    if (g_icon_added) {
      // Explorer took the icon with it while restarting; add it back.
      g_icon_added = false;
      AddTrayIcon();
    }
    return true;
  }

  if (message != kTrayCallbackMessage || !g_icon_added) return false;
  HandleTrayCallback(LOWORD(lparam));
  return true;
}

void RemoveTrayIcon() {
  if (!g_icon_added || g_main_window == nullptr) {
    g_icon_added = false;
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(NOTIFYICONDATAW);
  data.hWnd = g_main_window;
  data.uID = kTrayIconId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  g_icon_added = false;
}
