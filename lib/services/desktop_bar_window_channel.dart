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
  ///
  /// [ballGap] / [ballRatio] 是悬浮球的占位参数（两者都为 0 表示没有球）：
  /// 原生按 `ballGap + 胶囊高 × ballRatio` 算出让位宽度并把胶囊左移半个让位，
  /// 让「胶囊 + 悬浮球」这一对在屏幕上整体居中。数值与球窗口侧完全一致，
  /// 两边算出的整数必然相同。
  static Future<void> configure({
    required String position,
    required String layer,
    required bool clickThrough,
    required double opacity,
    required double barHeight,
    required double barWidth,
    required double screenMargin,
    required double ballGap,
    required double ballRatio,
  }) {
    return _channel.invokeMethod<void>('configure', {
      'position': position,
      'layer': layer,
      'click_through': clickThrough,
      'opacity': opacity,
      'bar_height': barHeight,
      'bar_width': barWidth,
      'screen_margin': screenMargin,
      'ball_gap': ballGap,
      'ball_ratio': ballRatio,
    });
  }

  /// 查询当前「是否有程序在前台」（双外观切换的依据）。
  ///
  /// 原生用 `GetForegroundWindow()` 判定：桌面 / 外壳窗口、不可见 / 最小化、
  /// 或浮窗自身在前台都算「桌面态」，其余可见程序窗口算「前台态」。
  /// 浮窗每个内容 tick 拉一次（而不是原生推送），通道生命周期完全由 Dart
  /// 掌控，窗口/引擎 teardown 后不会有悬挂调用。
  static Future<bool> getForeground() async {
    final value = await _channel.invokeMethod<bool>('get_foreground');
    return value ?? false;
  }

  /// 淡出超时兜底（原生淡出约 140ms）：通道无应答时不要卡死内容推送。
  static const Duration _fadeTimeout = Duration(seconds: 1);

  /// 把窗口不透明度平滑降到 0（约 140ms，时长由原生控制）。
  ///
  /// 桌面态 ↔ 前台态交叉淡化的前半段：淡出期间窗口几何与内容缩放仍是
  /// **旧**外观，两者保持一致，不会出现尺寸错位。
  static Future<void> fadeOut() =>
      _channel.invokeMethod<void>('fade_out').timeout(_fadeTimeout);

  /// 把窗口不透明度从当前值平滑升到 [opacity]（约 220ms）。
  ///
  /// 交叉淡化的后半段：调用前窗口已经切到新几何（`configure` 时先压到全透明）。
  /// 淡入挂掉时调用方负责用一次不带动画的 `configure` 兜底，不能把窗口
  /// 留在全透明上。
  static Future<void> fadeIn({required double opacity}) => _channel
      .invokeMethod<void>('fade_in', {'opacity': opacity})
      .timeout(_fadeTimeout);

  /// 关闭浮窗（主窗口退出或用户关闭桌面课表时）。
  static Future<void> close() => _channel.invokeMethod<void>('close');
}
