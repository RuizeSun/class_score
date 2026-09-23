import 'package:flutter/material.dart';

import 'desktop_schedule_common.dart';

/// 胶囊外壳：桌面课表的三种外观（常态条 / 蓝色横幅 / 倒计时）都画在这一层里。
///
/// 为什么形状做在「外壳」而不是各外观自己身上：原生浮窗是按胶囊形状硬裁剪的
/// （`SetWindowRgn`，见 `windows/runner/desktop_bar_channel.cpp`），Flutter 侧必须
/// 画出与之重合的形状，否则胶囊两端会露出窗口底色的方块。集中在这一层后，三种
/// 外观只管把内容铺满，不再各自处理圆角。
class DesktopScheduleCapsule extends StatelessWidget {
  const DesktopScheduleCapsule({
    super.key,
    required this.scale,
    this.width,
    this.child,
  });

  /// 用户设置的缩放（同时作用于高度、圆角与字号）。
  final double scale;

  /// 胶囊宽度。
  ///
  /// 为空表示铺满可用宽度——桌面浮窗就用这种方式：窗口宽本身就是原生算好的胶囊
  /// 宽度。设置页预览传确定值（[DesktopBarMetrics.capsuleWidth] × 缩放）。
  /// 无论哪种方式，都不会超过可用宽度（窄屏时收缩，避免溢出）。
  final double? width;

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final height = DesktopBarMetrics.height * scale;

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final desired = width ?? available;
        final resolved =
            available.isFinite && desired > available ? available : desired;

        return SizedBox(
          width: resolved,
          height: height,
          child: ClipRRect(
            // 半径取高度一半：两端正好是半圆，与原生 CreateRoundRectRgn 一致。
            borderRadius: BorderRadius.circular(
              DesktopBarMetrics.capsuleRadius(scale),
            ),
            child: DecoratedBox(
              // 画在子内容之上（前景），否则会被外观自己的不透明底色盖住。
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  DesktopBarMetrics.capsuleRadius(scale),
                ),
                border: Border.all(color: DesktopBarPalette.capsuleBorder),
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
