#include "app_quit.h"

#include <windows.h>

#include "tray_icon.h"

void QuitApplicationNow() {
  // 图标必须先显式删除：进程直接消失时壳程序不会立刻收回图标。
  RemoveTrayIcon();
  // 桌面课表胶囊（multi_window 子窗口）与悬浮球都是本进程的窗口，随进程一起
  // 被系统销毁；这里刻意不调用任何窗口关闭 / 引擎收尾接口，那正是慢的来源。
  //
  // 用 TerminateProcess 而不是 ExitProcess：后者会替调用线程跑一遍各 DLL 的
  // DllMain(PROCESS_DETACH)，而 multi_window 插件的静态对象在 detach 时会去
  // 析构它托管的子引擎（就是那 3~5 秒），实测 ExitProcess 也要 4.8 秒才真的
  // 结束。TerminateProcess 直接终止所有线程，不做任何 detach 回调。
  ::TerminateProcess(::GetCurrentProcess(), 0);
}
