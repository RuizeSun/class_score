import 'package:flutter/material.dart';

import '../../models/desktop_schedule_state.dart';
import '../../services/schedule_timeline_service.dart';
import '../motion.dart';
import 'desktop_schedule_common.dart';

/// 上课倒计时条（图三 ↔ 图四）。
///
/// 两图文案共用同一层背景进度条：填充比例 = 已等待 / 整个提醒窗口时长，
/// 于是「背景在走」这件事在两图之间是连续的，只有文字在交替。
class DesktopScheduleCountdown extends StatelessWidget {
  const DesktopScheduleCountdown({
    super.key,
    required this.state,
    required this.showPreparationHint,
    this.scale = 1.0,
  });

  final DesktopScheduleState state;

  /// true 时显示图四（准备上课提醒），false 时显示图三（倒计时明细）。
  final bool showPreparationHint;

  final double scale;

  @override
  Widget build(BuildContext context) {
    final height = DesktopBarMetrics.height * scale;

    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: DesktopBarPalette.countdownBackground),
          // 背景进度条：随时间从左向右填充（下课 / 上课前都靠它表达“还剩多少”）
          AnimatedFractionallySizedBox(
            duration: AppMotion.resolve(
              context,
              const Duration(seconds: 1),
            ),
            curve: Curves.linear,
            alignment: Alignment.centerLeft,
            widthFactor: state.progress.clamp(0.0, 1.0),
            child: const ColoredBox(color: DesktopBarPalette.countdownFill),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: DesktopBarMetrics.capsulePadding * scale,
            ),
            child: FadeThroughSwitcher(
              switchKey: showPreparationHint,
              duration: AppMotion.medium,
              child: showPreparationHint
                  ? _buildPreparationHint(scale)
                  : _buildCountdown(scale),
            ),
          ),
        ],
      ),
    );
  }

  /// 图三：左侧倒计时、右侧「下节课是：课程 + 时间」。
  Widget _buildCountdown(double scale) {
    final next = state.nextSlot;
    final remaining = ScheduleTimelineService.formatCountdown(state.remaining);
    final left = '距上课还剩 ';

    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Text(
                  left,
                  style: TextStyle(
                    fontSize: 16 * scale,
                    color: Colors.white70,
                  ),
                ),
                Text(
                  remaining,
                  style: TextStyle(
                    fontSize: 18 * scale,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 胶囊宽度有限：课程名过长时让它省略，而不是把整行挤到溢出。
        if (next != null)
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '下节课是：',
                  style: TextStyle(
                    fontSize: 16 * scale,
                    color: Colors.white70,
                  ),
                ),
                Flexible(
                  child: Text(
                    next.courseName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18 * scale,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                SizedBox(width: 8 * scale),
                Text(
                  next.timeRange,
                  style: TextStyle(
                    fontSize: 15 * scale,
                    color: Colors.white60,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 图四：居中的准备提醒。
  Widget _buildPreparationHint(double scale) {
    return Center(
      child: Text(
        '准备上课，请回到座位并保持安静，做好上课准备。',
        style: TextStyle(
          fontSize: 17 * scale,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
    );
  }
}
