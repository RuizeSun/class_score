#include "flutter_window.h"

#include <optional>

#include "desktop_ball_window.h"
#include "desktop_bar_channel.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "flutter/generated_plugin_registrant.h"
#include "tray_icon.h"

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
  // Close-to-tray and the floating ball belong to the main window: both are
  // plain runner-side windows/channels (no extra engine), so they are
  // registered here - never in the multi-window callback below, which also
  // fires for the capsule engine.
  RegisterTrayChannel(flutter_controller_.get(), GetHandle());
  RegisterDesktopBallChannel(flutter_controller_.get(), GetHandle());
  // Extra engines created by desktop_multi_window must NOT register the whole
  // plugin set: window_manager keeps its method channel in a process-wide
  // global and uses COM taskbar objects, so a second registration hijacks the
  // main window's channel and crashes (access violation). The desktop schedule
  // bar only needs its own native channel, registered here.
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    RegisterDesktopBarWindowChannel(flutter_view_controller);
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
  // The tray icon and the floating ball live and die with this window: take
  // them down first so no ghost tray entry or orphan ball outlives it.
  RemoveTrayIcon();
  DestroyDesktopBallWindow();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Tray icon callbacks and the explorer-restart broadcast are ours; check
  // them before handing the message to Flutter (which does not know them).
  if (HandleTrayMessage(hwnd, message, wparam, lparam)) {
    return 0;
  }

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
