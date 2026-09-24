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

/// 一套完整的桌面课表外观（位置、层级、穿透、透明度、缩放）。
///
/// 桌面课表可以配置两套外观：**桌面态**（无程序遮挡）与**前台态**（有程序窗口
/// 在前台），由 [pickDesktopBarAppearance] 按当前状态选出实际生效的那一套。
/// 抽成不可变值对象后，选择逻辑是纯函数，可脱离数据库 / 窗口直接单测。
class DesktopBarAppearance {
  const DesktopBarAppearance({
    required this.position,
    required this.layer,
    required this.clickThrough,
    required this.opacity,
    required this.scale,
  });

  final DesktopBarPosition position;
  final DesktopBarLayer layer;
  final bool clickThrough;

  /// 0.3 – 1.0，与设置页滑块范围一致。
  final double opacity;

  /// 0.8 – 1.6，与设置页滑块范围一致。
  final double scale;
}

/// 按「双外观开关 + 当前是否有程序在前台」选出实际生效的外观。
///
/// - 开关关闭：无论前台与否都用桌面态 [desktop]（老行为不变）；
/// - 开关开启：桌面态用 [desktop]，有程序在前台时用 [foreground]。
DesktopBarAppearance pickDesktopBarAppearance({
  required bool foregroundEnabled,
  required bool foregroundActive,
  required DesktopBarAppearance desktop,
  required DesktopBarAppearance foreground,
}) {
  if (foregroundEnabled && foregroundActive) return foreground;
  return desktop;
}

/// 「桌面态 ↔ 前台态」切换时是否播放交叉淡化过渡。
///
/// 三个条件缺一不可：
/// - [alreadyApplied]：已经有过一版外观，才谈得上「切换」（首次出现由调用方
///   单独淡入，不走交叉淡化）；
/// - [foregroundFlipped]：前台状态真的翻转了——设置页改参数、拖不透明度 /
///   缩放滑块时前台标记没变，直接生效，避免连续拖动引发闪烁；
/// - [appearanceChanged]：生效外观的签名变了——两套外观配得完全相同时
///   原地淡出再淡入只会白闪一下。
bool shouldAnimateDesktopBarSwitch({
  required bool alreadyApplied,
  required bool foregroundFlipped,
  required bool appearanceChanged,
}) =>
    alreadyApplied && foregroundFlipped && appearanceChanged;
