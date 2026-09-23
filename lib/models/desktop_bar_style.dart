/// 桌面课表胶囊在屏幕上的停靠位置。
///
/// 三种锚点**都是水平居中**：胶囊宽度固定（见 `DesktopBarMetrics.capsuleWidth`），
/// 不再铺满屏幕宽度，因此桌面左侧的快捷方式不会被盖住。
enum DesktopBarPosition {
  /// 顶部居中：水平居中、距工作区顶部 16 逻辑像素（默认）。
  top('顶部居中'),

  /// 中央偏上：水平居中、落在工作区约 1/4 高度处。
  upperCenter('中央偏上'),

  /// 底部居中：水平居中、距工作区底部 16 逻辑像素。
  bottom('底部居中');

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
