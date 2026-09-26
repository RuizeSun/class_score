#ifndef RUNNER_DESKTOP_BAR_CHANNEL_H_
#define RUNNER_DESKTOP_BAR_CHANNEL_H_

#include <flutter/flutter_view_controller.h>

#include <windows.h>

// Registers a native method channel for the desktop schedule bar window.
//
// Why native instead of window_manager: window_manager keeps its method
// channel in a process-wide global and uses COM (taskbar) objects, so
// registering/using it from a second engine hijacks the main window channel
// and crashes with an access violation. The bar needs only a few window style
// bits, so it is done here directly with Win32 APIs.
void RegisterDesktopBarWindowChannel(
    flutter::FlutterViewController* view_controller);

// The capsule's top-level window, recorded whenever the bar engine applies an
// appearance (nullptr until the capsule exists). The floating ball derives its
// position from this handle's real rect, so the two windows can never drift
// apart - the channel is only ever invoked by the bar engine, which is why the
// handle cannot point at some other window.
HWND GetDesktopBarWindow();

// Work area (taskbar excluded) of the monitor |hwnd| currently sits on.
RECT GetDesktopWorkArea(HWND hwnd);

#endif  // RUNNER_DESKTOP_BAR_CHANNEL_H_

