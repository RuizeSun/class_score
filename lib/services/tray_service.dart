import 'package:flutter/services.dart';

import 'desktop_bar_log.dart';
import 'desktop_window_service.dart';

/// 系统托盘的 Dart 侧（原生实现见 `windows/runner/tray_icon.cpp`）。
///
/// 关闭主窗口时窗口只是隐藏、程序仍在跑：托盘图标就是「回到程序 / 彻底退出」
/// 的入口之一（另一个是桌面悬浮球）。图标、右键菜单与气泡提示都在原生侧，
/// Dart 只负责按设置开关图标，并处理原生回传的命令。
class TrayService {
  TrayService._();

  static const MethodChannel _channel = MethodChannel('class_score/tray');

  /// 通道无应答时的兜底：托盘/悬浮球的调用都发生在交互路径上，绝不能因为
  /// 原生没回消息就把调用方（比如关闭窗口）卡住。
  static const Duration _callTimeout = Duration(seconds: 4);

  /// 首次进托盘才提示一次：每次都弹气泡会很吵。
  static bool _hintShown = false;

  /// 挂载原生事件（原生 → Dart）。
  static void attach({
    required Future<void> Function() onShow,
    required Future<void> Function() onHide,
    required Future<void> Function() onQuit,
  }) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'on_command') {
        final command = call.arguments as String?;
        if (command == 'show') {
          await onShow();
        } else if (command == 'hide') {
          await onHide();
        } else if (command == 'quit') {
          await onQuit();
        }
        return null;
      }
      throw MissingPluginException('未实现的托盘方法：${call.method}');
    });
  }

  /// 显示 / 隐藏托盘图标（跟随「关闭窗口时最小化到托盘」设置）。
  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel
          .invokeMethod<void>('set_enabled', {'enabled': enabled})
          .timeout(_callTimeout);
      await DesktopBarLog.write(
        DesktopWindowService.mainTag,
        '托盘图标：${enabled ? '已显示' : '已隐藏'}',
      );
    } catch (error) {
      await DesktopBarLog.write(
        DesktopWindowService.mainTag,
        '设置托盘图标失败：$error',
      );
    }
  }

  /// 第一次隐藏到托盘时的提示气泡（整个会话只弹一次）。
  static Future<void> showFirstCloseHint() async {
    if (_hintShown) return;
    _hintShown = true;
    try {
      await _channel.invokeMethod<void>('show_balloon').timeout(_callTimeout);
    } catch (error) {
      await DesktopBarLog.write(
        DesktopWindowService.mainTag,
        '显示托盘提示失败：$error',
      );
    }
  }
}
