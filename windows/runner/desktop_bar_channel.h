#ifndef RUNNER_DESKTOP_BAR_CHANNEL_H_
#define RUNNER_DESKTOP_BAR_CHANNEL_H_

#include <flutter/flutter_view_controller.h>

// Registers a native method channel for the desktop schedule bar window.
//
// Why native instead of window_manager: window_manager keeps its method
// channel in a process-wide global and uses COM (taskbar) objects, so
// registering/using it from a second engine hijacks the main window channel
// and crashes with an access violation. The bar needs only a few window style
// bits, so it is done here directly with Win32 APIs.
void RegisterDesktopBarWindowChannel(
    flutter::FlutterViewController* view_controller);

#endif  // RUNNER_DESKTOP_BAR_CHANNEL_H_
