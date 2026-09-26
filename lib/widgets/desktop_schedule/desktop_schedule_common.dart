import 'package:flutter/material.dart';

import '../../models/weather_snapshot.dart';

/// 桌面条的统一配色与尺寸。
///
/// 六张图的配色其实只有三套：深色常态条、蓝色横幅（图二 / 图五）、灰色倒计时
/// （图三 / 图四）。集中放在这里，避免各处硬编码同一个色值后出现色差。
class DesktopBarPalette {
  DesktopBarPalette._();

  /// 常态条底色（深蓝黑，略带透明以贴近「桌面挂件」观感）。
  static const Color barBackground = Color(0xFF141A24);

  /// 常态条里「非当前」课程文字颜色。
  static const Color idleText = Color(0xFFCBD5E1);

  /// 当前时段块的底色（比条底稍亮）；课间休息时用更暗一档的底色区分。
  static const Color activeChip = Color(0xFF2A3242);
  static const Color activeBreakChip = Color(0xFF232B39);

  static const Color activeText = Colors.white;

  /// 进度条 / 高亮的蓝色（图一底部进度条、图二 / 图五横幅）。
  static const Color accent = Color(0xFF5B86E5);
  static const Color accentDeep = Color(0xFF3F6BD8);

  /// 倒计时背景（图三 / 图四）与它的填充色。
  static const Color countdownBackground = Color(0xFF3F4652);
  static const Color countdownFill = Color(0xFF5A6373);

  /// 横幅上的正文颜色。
  static const Color bannerText = Colors.white;

  static const Color divider = Color(0xFF39414F);

  /// 胶囊内描边：原生窗口是按胶囊形状硬裁剪的（`SetWindowRgn`，1 位掩码），
  /// 描一圈很淡的亮边能让两端圆弧的裁剪边缘看起来更自然。
  static const Color capsuleBorder = Color(0x26FFFFFF);
}

/// 桌面课表胶囊的几何尺寸（逻辑像素，最终再乘用户设置的缩放）。
class DesktopBarMetrics {
  DesktopBarMetrics._();

  /// 胶囊高度（= 浮窗高度）。
  static const double height = 52;

  /// 胶囊宽度：固定宽度 + 水平居中，不再铺满屏幕。
  ///
  /// 整宽贴边的条会盖住桌面左侧的快捷方式，所以改成一块居中悬浮的胶囊。
  /// 浮窗的**实际**宽度由原生侧决定（窄屏时收缩为「工作区宽 − 2 ×
  /// [screenMargin]」，见 `windows/runner/desktop_bar_channel.cpp`），
  /// Flutter 侧只负责把内容铺满这个宽度，两边不会各算一套。
  static const double capsuleWidth = 720;

  /// 胶囊与屏幕工作区边缘的留白（`top` / `bottom` 锚点使用）。
  static const double screenMargin = 16;

  /// 悬浮球与胶囊右端的间距：原生侧把它换算成「让位宽度」的一部分，
  /// 使「胶囊 + 悬浮球」这一对在屏幕上整体居中（见
  /// `windows/runner/desktop_bar_channel.cpp` 的 reserve 计算）。
  static const double ballGap = 12;

  /// 内容左右留白：不小于半高，避免文字压在胶囊两端的圆弧上。
  static const double capsulePadding = 22;

  /// 胶囊圆角半径（= 高度一半，两端正好是半圆）。
  static double capsuleRadius(double scale) => height * scale / 2;

  /// 课程块之间的间距。
  static const double chipSpacing = 14;

  /// 课程块内部左右留白。
  static const double chipPadding = 10;

  /// 常态条底部进度条厚度。
  static const double progressThickness = 2.5;

  /// 天气图标大小。
  static const double weatherIconSize = 18;
}

/// 推给桌面浮窗的悬浮球占位参数。
///
/// 球关掉时两者归零：原生的让位宽度为 0，胶囊回到「水平居中」的老布局，
/// 因此开关悬浮球不会影响没开悬浮球的用户。
///
/// 球的直径恒等于胶囊高度（[ratio] 恒为 1，见
/// `windows/runner/desktop_ball_window.cpp`）：球与胶囊同色同高、拼在一起读作
/// 同一个挂件，所以不再有单独的「悬浮球大小」比例设置。
class DesktopBallReserve {
  const DesktopBallReserve(this.gap, this.ratio);

  /// 胶囊与球之间的间距（逻辑像素）。
  final double gap;

  /// 球径占胶囊高度的比例（恒为 1 = 与胶囊等高；0 表示没有球）。
  final double ratio;

  static const DesktopBallReserve none = DesktopBallReserve(0, 0);
}

/// 球开着时让位，并声明「球径 = 胶囊高」。
DesktopBallReserve desktopBallReserve({required bool ballEnabled}) =>
    ballEnabled
        ? const DesktopBallReserve(DesktopBarMetrics.ballGap, 1)
        : DesktopBallReserve.none;

/// WMO 天气类型 → 图标（与 [WeatherSnapshot.kindOf] 的归一化结果一一对应）。
IconData weatherIconOf(WeatherKind kind) {
  switch (kind) {
    case WeatherKind.clear:
      return Icons.wb_sunny_outlined;
    case WeatherKind.mainlyClear:
      return Icons.wb_cloudy_outlined;
    case WeatherKind.partlyCloudy:
      return Icons.cloud_queue;
    case WeatherKind.overcast:
      return Icons.cloud;
    case WeatherKind.fog:
      return Icons.foggy;
    case WeatherKind.drizzle:
      return Icons.grain;
    case WeatherKind.freezingRain:
      return Icons.ac_unit;
    case WeatherKind.rain:
      return Icons.umbrella;
    case WeatherKind.snow:
      return Icons.ac_unit;
    case WeatherKind.rainShowers:
      return Icons.water_drop_outlined;
    case WeatherKind.snowShowers:
      return Icons.ac_unit;
    case WeatherKind.thunderstorm:
      return Icons.thunderstorm_outlined;
    case WeatherKind.unknown:
      return Icons.cloud_outlined;
  }
}
