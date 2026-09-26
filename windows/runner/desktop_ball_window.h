#ifndef RUNNER_DESKTOP_BALL_WINDOW_H_
#define RUNNER_DESKTOP_BALL_WINDOW_H_

#include <flutter/flutter_view_controller.h>
#include <windows.h>

// The floating ball is a runner-owned native window: it never spawns a third
// Flutter engine, it just needs the main engine's method channel to be told
// where to sit and to report clicks / drags / menu picks back to Dart.
//
// Why native: the capsule keeps its own WS_EX_TRANSPARENT (mouse
// click-through) setting, and Win32 cannot make *part* of a window
// click-through (HTTRANSPARENT only forwards within a thread). Giving the ball
// its own window is therefore the only way to keep the capsule click-through
// while the ball stays clickable.
//
// Geometry rule: next to the capsule the ball reads the capsule window's real
// rect (so it always matches, including the centre-shifted reserve, narrow
// screens and the second foreground appearance); otherwise it parks itself at
// the work-area's top-right corner with the user's saved offsets. In both cases
// the ball is exactly as tall as the capsule, filled with the capsule's own
// background colour and marked with the Material "school" icon - the ball is
// meant to read as part of the capsule rather than as a widget of its own.
void RegisterDesktopBallChannel(flutter::FlutterViewController* view_controller,
                                HWND main_window);

// Hides and destroys the ball window (app exit / channel "close").
void DestroyDesktopBallWindow();

#endif  // RUNNER_DESKTOP_BALL_WINDOW_H_
