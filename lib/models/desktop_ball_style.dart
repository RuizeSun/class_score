/// 桌面悬浮球的落点模式。
enum DesktopBallMode {
  /// 贴在桌面课表胶囊右侧：原生侧读胶囊窗口的真实矩形对齐，
  /// 「胶囊 + 悬浮球」组合整体居中于屏幕。
  besideBar('贴着课表胶囊'),

  /// 屏幕右上角（默认），可拖动调整，位置自动记忆。
  corner('屏幕右上角');

  const DesktopBallMode(this.label);

  final String label;
}

/// 悬浮球直径的默认比例（= 胶囊高度 × 该比例，随「整体缩放」一起变大变小）。
const double defaultBallSizeRatio = 0.85;
const double minBallSizeRatio = 0.6;
const double maxBallSizeRatio = 1.2;

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
