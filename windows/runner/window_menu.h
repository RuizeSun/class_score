#ifndef RUNNER_WINDOW_MENU_H_
#define RUNNER_WINDOW_MENU_H_

#include <windows.h>

#include <vector>

// A single entry of the popup menus shared by the tray icon and the floating
// ball. An id of 0 renders a separator line.
struct WindowMenuItem {
  UINT id;
  const wchar_t* label;
};

// Pops a menu at |pt| (screen coordinates) and returns the id of the picked
// item, or 0 when the menu is dismissed without a selection.
//
// The tray icon and the floating ball both offer 「显示主窗口 / 隐藏主窗口 /
// 退出程序」; two copies of this Win32 dance always drift apart, so they share
// one implementation here.
UINT ShowWindowMenu(HWND owner, const std::vector<WindowMenuItem>& items,
                    POINT pt);

#endif  // RUNNER_WINDOW_MENU_H_
