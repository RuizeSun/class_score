/// 桌面课表条在屏幕上的停靠位置。
enum DesktopBarPosition {
  top('顶部'),
  bottom('底部');

  const DesktopBarPosition(this.label);

  final String label;
}

/// 桌面课表条的窗口层级。
enum DesktopBarLayer {
  /// 桌面级：贴在桌面之上、被其它窗口遮挡（默认，最接近「只在桌面显示」）。
  desktop('桌面级'),

  /// 置顶：始终显示在所有窗口之上。
  topMost('置顶显示');

  const DesktopBarLayer(this.label);

  final String label;
}
