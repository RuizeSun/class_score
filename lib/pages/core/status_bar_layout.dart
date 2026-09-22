import 'dart:ui';

/// 顶部状态栏（胶囊条）的固定布局尺寸。
///
/// 状态栏由 HomePage 绘制，而解锁浮动面板需要「停在状态栏下方」且
/// 「模糊层避开状态栏」，两者必须共用同一份数据；这里集中定义，
/// 避免各处硬编码同一个数字后改一处漏一处。
class StatusBarMetrics {
  StatusBarMetrics._();

  /// 状态栏四周的留白（胶囊条距窗口边缘的距离）。
  static const double inset = 16;

  /// 胶囊条自身高度。
  static const double height = 40;

  /// 胶囊条圆角半径（= height / 2，两端为半圆）。
  static const double radius = height / 2;

  /// 状态栏底边相对窗口顶部的 y 坐标（= inset + height = 56）。
  static const double bottom = inset + height;

  /// 解锁时「保持清晰」的区域在胶囊条基础上向外扩张的余量（逻辑像素）。
  ///
  /// 取 1 逻辑像素即可：既盖住胶囊条自身的抗锯齿边缘，避免裁剪边界与胶囊
  /// 边缘之间露出缝隙，又不会把过多模糊背景留成清晰区。
  static const double _clarityBleed = 1;

  /// 解锁时保持清晰、不参与模糊的区域（胶囊条轮廓 + 1px 抗锯齿余量）。
  ///
  /// 解锁模糊层会把这个圆角矩形从整窗中「挖空」，于是清晰区边界正好落在
  /// 胶囊自身的轮廓上：既不会像水平直切那样把胶囊底部和它的投影切断，
  /// 模糊背景与状态栏之间也不再有突兀的横向硬边。
  static RRect clarityRRect(Size windowSize) {
    final rect = Rect.fromLTWH(
      inset - _clarityBleed,
      inset - _clarityBleed,
      windowSize.width - (inset - _clarityBleed) * 2,
      height + _clarityBleed * 2,
    );
    return RRect.fromRectAndRadius(
      rect,
      const Radius.circular(radius + _clarityBleed),
    );
  }
}
