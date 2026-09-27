/// 桌面悬浮球的落点模式。
enum DesktopBallMode {
  /// 贴在桌面课表胶囊右侧：原生侧读胶囊窗口的真实矩形对齐，
  /// 「胶囊 + 悬浮球」组合整体居中于屏幕；球与胶囊同色同高，读作同一个挂件。
  besideBar('贴着课表胶囊'),

  /// 屏幕右上角（默认），可拖动调整，位置自动记忆。
  corner('屏幕右上角');

  const DesktopBallMode(this.label);

  final String label;
}

/// 拖动偏移的允许范围（逻辑像素，相对右上角默认位置）。
///
/// 设置页没有偏移滑块——位置只来自拖动；这里给一个足够宽但仍安全的范围，
/// 用来兜住跨屏分辨率突变或解析异常，不让球被送去屏幕外。
const double minBallOffset = -2000;
const double maxBallOffset = 2000;

/// 选一种落点。
///
/// 用「胶囊是否真的在屏上」而不是「课表开关是否打开」：课表开关刚打开时胶囊
/// 还在创建退避里，此时按右上角显示，等胶囊出现后下一拍自动贴过去。
DesktopBallMode pickDesktopBallMode({required bool barVisible}) =>
    barVisible ? DesktopBallMode.besideBar : DesktopBallMode.corner;

/// 夹紧拖动得到的偏移，避免异常值把球留在屏幕外。
double clampBallOffset(double value) => value.clamp(minBallOffset, maxBallOffset);

/// 主窗口是否正显示在屏幕上（未最小化、未收进托盘）。
///
/// 两个输入直接来自 `windowManager.isVisible()` / `isMinimized()`：
/// - 收进托盘（[WindowCloseAction.hideToTray]）→ `visible == false`；
/// - 最小化 → `visible == true` 但 `minimized == true`。
///
/// 用「窗口是否就在眼前」而不是「是否获得焦点」：程序已经打开摆在屏幕上时，
/// 悬浮球这个入口就是多余的；只有收进托盘 / 最小化之后才需要它把窗口叫回来。
bool appWindowOnScreen({required bool visible, required bool minimized}) =>
    visible && !minimized;

/// 悬浮球现在是否该出现在屏幕上。
///
/// 开关关掉时永远不显示（此时窗口会被销毁，见 [DesktopBallService.close]）；
/// 主窗口在屏上时也不显示——球是「叫回窗口」的入口，窗口就在眼前时它没有意义。
bool shouldShowDesktopBall({
  required bool ballEnabled,
  required bool onScreen,
}) => ballEnabled && !onScreen;
