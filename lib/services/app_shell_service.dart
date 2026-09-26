import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

import 'desktop_ball_service.dart';
import 'desktop_bar_log.dart';
import 'desktop_window_service.dart';

/// 托盘与悬浮球共用的应用级窗口动作。
///
/// 两处入口（托盘菜单、球的单击 / 右键菜单）都要「显示主窗口」与「退出程序」，
/// 各写一遍必然走样；退出更要统一先收掉桌面上的子窗口（课表胶囊、悬浮球），
/// 否则会留下收不到状态的孤窗。
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

  /// 彻底退出：先关课表胶囊与悬浮球，再销毁主窗口
  /// （window_manager 的 destroy 即 PostQuitMessage，消息循环结束后进程退出）。
  ///
  /// 子窗口的关闭只是「别留孤窗」，不能因为某个通道没回消息就把退出卡住：
  /// 两条关闭指令都是发出即走（各自内部有超时），短暂等待后一律销毁主窗口；
  /// 连销毁都没成功的话兜底强杀进程——托盘应用绝不能出现「点退出没反应」。
  static Future<void> quitApplication() async {
    unawaited(DesktopBallService.close());
    unawaited(DesktopWindowService.closeBar());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      await windowManager.destroy().timeout(const Duration(seconds: 2));
    } catch (error) {
      await _log('退出程序失败（强制结束进程）：$error');
      exit(0);
    }
  }
}
