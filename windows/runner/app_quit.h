#ifndef RUNNER_APP_QUIT_H_
#define RUNNER_APP_QUIT_H_

// 「退出程序」的唯一实现（托盘菜单 / 悬浮球菜单 / Dart 的「关闭即退出」共用）。
//
// 为什么不用 PostQuitMessage / window_manager.destroy()：那只是往消息队列丢一条
// WM_QUIT，之后进程还要走完「销毁子窗口 → 各 Flutter 引擎 shutdown」的收尾路径
// （桌面课表子引擎跑在独立线程上，收尾要把它 join 掉），实测要 5.8 秒才真的消失。
//
// 也不用 ExitProcess：它会替调用线程跑一遍各 DLL 的 DllMain(PROCESS_DETACH)，
// 而 multi_window 插件的静态对象在 detach 时会把托管的子引擎析构掉——实测同样
// 要 4.8 秒。TerminateProcess 不做任何回调，直接终止所有线程：胶囊 / 悬浮球窗口
// 随进程被系统销毁，托盘图标在退出前显式摘掉，实测 0.14 秒。
//
// 数据侧没有待落盘的收尾动作（SQLite 每笔写入即提交），所以可以放心硬终止。
// 必须在主线程（窗口消息处理中）调用。
void QuitApplicationNow();

#endif  // RUNNER_APP_QUIT_H_
