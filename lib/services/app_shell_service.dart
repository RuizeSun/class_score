import 'dart:io';

import 'package:window_manager/window_manager.dart';

import 'desktop_bar_log.dart';
import 'desktop_window_service.dart';
import 'tray_service.dart';

/// 托盘与悬浮球共用的应用级窗口动作。
///
/// 两处入口（托盘菜单、球的单击 / 右键菜单）都要「显示主窗口」与「退出程序」，
/// 各写一遍必然走样，所以统一收在这里。
class AppShellService {
  AppShellService._();

  static Future<void> _log(String message) =>
      DesktopBarLog.write(DesktopWindowService.mainTag, message);

  /// 从托盘 / 悬浮球回到主窗口（可能已被最小化，所以先 restore 再 show）。
  static Future<void> showMainWindow() async {
    try {
      await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } catch (error) {
      await _log('显示主窗口失败：$error');
    }
  }

  static Future<void> hideMainWindow() async {
    try {
      await windowManager.hide();
    } catch (error) {
      await _log('隐藏主窗口失败：$error');
    }
  }

  /// 彻底退出。
  ///
  /// 交给原生的「立即退出」（`windows/runner/app_quit.cpp`：摘掉托盘图标 →
  /// `TerminateProcess`），**不用** `window_manager.destroy()`：那只是
  /// `PostQuitMessage(0)`，之后进程还要走完「关子窗口 → 各 Flutter 引擎
  /// shutdown」的收尾路径（桌面课表子引擎跑在独立线程上），实测点完要等
  /// 5.8 秒才真正消失。托盘图标必须由原生先摘掉，所以这里不能只 `exit(0)`。
  ///
  /// 原生通道不可用（测试环境 / 非 Windows）时兜底直接终止进程：托盘应用
  /// 绝不能出现「点退出没反应」。
  static Future<void> quitApplication() async {
    try {
      await TrayService.quitNow().timeout(_nativeQuitTimeout);
    } catch (error) {
      await _log('原生退出无应答，改由 Dart 直接结束进程：$error');
    }
    exit(0);
  }

  /// 原生「立即退出」的等待上限：正常情况下进程在通道那一步就没了，
  /// 只有原生缺席时才会走到后面的兜底。
  static const Duration _nativeQuitTimeout = Duration(seconds: 1);
}
