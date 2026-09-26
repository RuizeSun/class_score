#include "window_menu.h"

namespace {

// The classic Win32 menu quirks, collected in one place:
//  - TrackPopupMenu only returns when TPM_RETURNCMD is set, and it wants the
//    owner to be the foreground window beforehand, otherwise the menu closes on
//    the very first click elsewhere;
//  - a WM_NULL afterwards makes the menu dismiss correctly when the user picks
//    nothing (the owner never sees the "missing" WM_SYSCOMMAND).
UINT TrackMenu(HWND owner, HMENU menu, POINT pt) {
  SetForegroundWindow(owner);
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, 0,
      owner, nullptr);
  PostMessageW(owner, WM_NULL, 0, 0);
  return command;
}

}  // namespace

UINT ShowWindowMenu(HWND owner, const std::vector<WindowMenuItem>& items,
                    POINT pt) {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return 0;

  for (const WindowMenuItem& item : items) {
    if (item.id == 0) {
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      continue;
    }
    AppendMenuW(menu, MF_STRING, item.id, item.label);
  }

  const UINT command = TrackMenu(owner, menu, pt);
  DestroyMenu(menu);
  return command;
}
