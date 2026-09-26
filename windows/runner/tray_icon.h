#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <flutter/flutter_view_controller.h>
#include <windows.h>

// Message the shell posts to the main window for tray-icon events (left/right
// click, double click, ...).
constexpr UINT kTrayCallbackMessage = WM_APP + 1;

// Registers `class_score/tray` on the main engine.
//
// Dart turns the icon on and off (「关闭窗口时最小化到托盘」开关) and receives
// the menu picks back as `on_command("show"|"hide"|"quit")`. The icon itself
// comes from the exe's own resource, so no loose .ico file is needed at
// runtime.
void RegisterTrayChannel(flutter::FlutterViewController* view_controller,
                         HWND main_window);

// Routes tray-related window messages. Returns true when consumed. Also
// covers `TaskbarCreated`, so the icon comes back after an explorer restart.
bool HandleTrayMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

// Removes the icon before the window goes away (no ghost entry left in the
// tray until the mouse sweeps over it).
void RemoveTrayIcon();

#endif  // RUNNER_TRAY_ICON_H_
