import 'package:flutter/material.dart';

import 'desktop_schedule_common.dart';

/// 蓝色提示横幅（图二「即将上课」/ 图五「上课」）。
///
/// 只负责「一条铺满整宽的蓝底提示」长什么样；什么时候出现、显示多久由时间线
/// 状态机决定（见 `ScheduleTimelineService`），这样横幅本身可以被单独测试。
class DesktopNoticeBanner extends StatelessWidget {
  const DesktopNoticeBanner({
    super.key,
    required this.text,
    this.icon = Icons.error_outline,
    this.trailingIcon = Icons.meeting_room_outlined,
    this.scale = 1.0,
  });

  /// 主文案（「即将上课」/「上课」）。
  final String text;

  /// 左侧图标（对应图中的 ⓘ）。
  final IconData icon;

  /// 右侧图标（对应图中的门 / 铃声图标）。
  final IconData trailingIcon;

  final double scale;

  @override
  Widget build(BuildContext context) {
    final height = DesktopBarMetrics.height * scale;

    return SizedBox(
      height: height,
      width: double.infinity,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [DesktopBarPalette.accent, DesktopBarPalette.accentDeep],
          ),
        ),
        child: TweenAnimationBuilder<double>(
          // 从左右微微「撑开」+ 淡入：横幅是突然出现的提醒，需要一点入场感，
          // 但不能有位移，否则整条提示会看起来像在抖动。
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.scale(
              scaleX: 0.94 + 0.06 * value,
              child: child,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 20 * scale,
                color: DesktopBarPalette.bannerText,
              ),
              SizedBox(width: 10 * scale),
              Text(
                text,
                style: TextStyle(
                  fontSize: 17 * scale,
                  fontWeight: FontWeight.bold,
                  color: DesktopBarPalette.bannerText,
                ),
              ),
              SizedBox(width: 10 * scale),
              Icon(
                trailingIcon,
                size: 20 * scale,
                color: DesktopBarPalette.bannerText,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
