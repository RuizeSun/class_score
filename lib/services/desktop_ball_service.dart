import 'package:flutter/services.dart';

import '../models/desktop_ball_style.dart';
import '../models/desktop_bar_style.dart';
import '../models/desktop_schedule_state.dart';
import 'desktop_bar_log.dart';
import 'desktop_window_service.dart';

/// 桌面悬浮球的主窗口侧编排（原生窗口见
/// `windows/runner/desktop_ball_window.cpp`）。
///
/// 球是 runner 直接创建的**原生**窗口，不占第三个 Flutter 引擎：这里只把设置
/// 推过去（落点 / 大小 / 层级 / 透明度 / 主题色），再把原生回传的事件
/// （单击、拖动、右键菜单）转成应用动作。
class DesktopBallService {
  DesktopBallService._();

  static const MethodChannel _channel = MethodChannel(
    'class_score/desktop_ball_window',
  );

  /// 通道无应答时的兜底（与托盘同一套约定）：配置/关闭都发生在交互路径上，
  /// 原生万一没回消息也不能把调用方（尤其是「退出程序」）卡住。
  static const Duration _callTimeout = Duration(seconds: 4);

  static Future<void> _log(String message) =>
      DesktopBarLog.write(DesktopWindowService.mainTag, message);

  /// 挂载原生事件（原生 → Dart）。
  static void attach({
    required Future<void> Function() onShow,
    required Future<void> Function() onHide,
    required Future<void> Function() onQuit,
    required Future<void> Function(double offsetX, double offsetY) onMoved,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'on_click':
          await onShow();
          return null;
        case 'on_moved':
          final args = asStringKeyedMap(call.arguments);
          await onMoved(
            (args['offset_x'] as num?)?.toDouble() ?? 0,
            (args['offset_y'] as num?)?.toDouble() ?? 0,
          );
          return null;
        case 'on_command':
          final command = call.arguments as String?;
          if (command == 'show') {
            await onShow();
          } else if (command == 'hide') {
            await onHide();
          } else if (command == 'quit') {
            await onQuit();
          }
          return null;
        default:
          throw MissingPluginException('未实现的悬浮球方法：${call.method}');
      }
    });
  }

  /// 推一次落点与外观。
  ///
  /// [DesktopBallMode.besideBar] 时原生读**胶囊窗口的真实矩形**来对齐，并镜像
  /// 它的层级 / 不透明度（前台态换一套外观也自动跟随），因此这里只额外给
  /// [gap]；[offsetX] / [offsetY] 只在右上角（[DesktopBallMode.corner]）生效。
  static Future<void> configure({
    required DesktopBallMode mode,
    required bool enabled,
    required double sizeRatio,
    required double capsuleHeight,
    required double gap,
    required double margin,
    required double offsetX,
    required double offsetY,
    required DesktopBarLayer layer,
    required double opacity,
    required int color,
  }) async {
    try {
      await _channel
          .invokeMethod<void>('configure', {
            'mode': mode == DesktopBallMode.besideBar ? 'beside' : 'corner',
            'enabled': enabled,
            'size_ratio': sizeRatio,
            'capsule_height': capsuleHeight,
            'gap': gap,
            'margin': margin,
            'offset_x': offsetX,
            'offset_y': offsetY,
            'layer': layer.name,
            'opacity': opacity,
            'color': color,
          })
          .timeout(_callTimeout);
      await _log(
        '悬浮球：落点=${mode.label} 比例=$sizeRatio '
        '偏移=(${offsetX.round()}, ${offsetY.round()})',
      );
    } catch (error) {
      await _log('配置悬浮球失败：$error');
    }
  }

  /// 彻底关掉球窗口（球开关关闭 / 应用退出时调用；下次开启会重建）。
  static Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close').timeout(_callTimeout);
    } catch (error) {
      await _log('关闭悬浮球失败：$error');
    }
  }
}
