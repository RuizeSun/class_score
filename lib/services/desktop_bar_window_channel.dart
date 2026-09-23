import 'package:flutter/services.dart';

/// 桌面条浮窗的**原生**窗口控制。
///
/// 对应实现见 `windows/runner/desktop_bar_channel.cpp`（由 runner 为浮窗引擎注册）。
///
/// 为什么不用 `window_manager`：它的 MethodChannel 是**进程级全局变量**，第二个
/// 引擎再注册会顶掉主窗口的通道；而且它的任务栏相关调用依赖 COM（浮窗引擎跑在
/// 独立线程上，没有初始化 COM）。实测在浮窗里调用会直接访问冲突崩溃
/// （window_manager_plugin.dll，0xC0000005）。桌面条只需要几个窗口样式位，
/// 交给原生的十几行 Win32 代码更稳。
class DesktopBarWindowChannel {
  DesktopBarWindowChannel._();

  static const MethodChannel _channel = MethodChannel(
    'class_score/desktop_bar_window',
  );

  /// 应用胶囊外观：无边框、不进任务栏、水平居中悬浮、按胶囊形状裁剪窗口
  /// （胶囊外的区域不显示也不接收点击），按 [barHeight] / [barWidth]（逻辑像素）
  /// 设置窗口尺寸（窄屏时原生会把宽度收缩到工作区内），照设置应用透明度与
  /// 鼠标穿透，最后把窗口显示出来。
  static Future<void> configure({
    required String position,
    required String layer,
    required bool clickThrough,
    required double opacity,
    required double barHeight,
    required double barWidth,
    required double screenMargin,
  }) {
    return _channel.invokeMethod<void>('configure', {
      'position': position,
      'layer': layer,
      'click_through': clickThrough,
      'opacity': opacity,
      'bar_height': barHeight,
      'bar_width': barWidth,
      'screen_margin': screenMargin,
    });
  }

  /// 关闭浮窗（主窗口退出或用户关闭桌面课表时）。
  static Future<void> close() => _channel.invokeMethod<void>('close');
}
