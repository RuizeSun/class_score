import 'package:flutter/material.dart';

import '../../models/desktop_schedule_state.dart';
import '../../models/weather_snapshot.dart';
import '../../services/schedule_timeline_service.dart';
import '../motion.dart';
import 'desktop_schedule_common.dart';

/// 常态条（图一 / 图六）：天气 + 今日课程横排，当前时段块高亮并带进度条。
///
/// 只接收「已算好的状态」，不订阅 Provider、不碰定时器：这样同一份组件既能
/// 在主窗口里做预览，也能在独立浮窗（另一个 isolate）里渲染同一份推送数据。
class DesktopScheduleBar extends StatelessWidget {
  const DesktopScheduleBar({
    super.key,
    required this.state,
    this.weatherLabel,
    this.weatherKind,
    this.scale = 1.0,
  });

  final DesktopScheduleState state;

  /// 天气温度文案（如「28℃」）；为空表示不显示天气块。
  final String? weatherLabel;
  final WeatherKind? weatherKind;

  /// 用户设置的缩放（同时作用于条高与字号）。
  final double scale;

  bool get _isBreak => state.phase == DesktopSchedulePhase.breakTime;

  /// 当前需要高亮的位置：上课中高亮本节课，课间高亮即将开始的那节课
  /// ——图一里「课间休息」块正是坐在下一节课的位置上。
  DateTime? get _activeStart {
    if (_isBreak) return state.nextSlot?.start;
    return state.currentSlot?.start;
  }

  /// 高亮块里的主文案。
  String get _activeTitle {
    if (_isBreak) return '课间休息';
    return state.currentSlot?.courseName ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final height = DesktopBarMetrics.height * scale;

    return Container(
      height: height,
      width: double.infinity,
      color: DesktopBarPalette.barBackground,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: DesktopBarMetrics.capsulePadding * scale),
          if (weatherLabel != null) _buildWeather(scale),
          Expanded(child: _buildCourses(scale)),
          SizedBox(width: DesktopBarMetrics.capsulePadding * scale),
        ],
      ),
    );
  }

  Widget _buildWeather(double scale) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: 10 * scale,
        horizontal: 2 * scale,
      ),
      child: Row(
        children: [
          Icon(
            weatherIconOf(weatherKind ?? WeatherKind.unknown),
            size: DesktopBarMetrics.weatherIconSize * scale,
            color: DesktopBarPalette.idleText,
          ),
          SizedBox(width: 6 * scale),
          Text(
            weatherLabel!,
            style: TextStyle(
              fontSize: 15 * scale,
              color: DesktopBarPalette.idleText,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(width: 12 * scale),
          Center(
            child: Container(
              width: 1,
              height: 18 * scale,
              color: DesktopBarPalette.divider,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCourses(double scale) {
    if (state.slots.isEmpty) {
      // 无课日 / 课表为空：只在常态条上留一句说明，不显示状态块
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '今日无课',
          style: TextStyle(
            fontSize: 15 * scale,
            color: DesktopBarPalette.idleText,
          ),
        ),
      );
    }

    final activeStart = _activeStart;
    final children = <Widget>[];
    for (final slot in state.slots) {
      if (children.isNotEmpty) {
        children.add(SizedBox(width: DesktopBarMetrics.chipSpacing * scale));
      }
      final isActive =
          activeStart != null && slot.start.isAtSameMomentAs(activeStart);
      children.add(
        isActive
            ? _ActiveChip(
                key: const ValueKey('desktop-schedule-active-chip'),
                title: _activeTitle,
                remaining: ScheduleTimelineService.formatChipRemaining(
                  state.remaining,
                ),
                progress: state.progress,
                isBreak: _isBreak,
                scale: scale,
              )
            : _CourseLabel(name: slot.courseName, scale: scale),
      );
    }

    // 课程较多 / 名称较长时允许横向滚动：桌面条宽度有限，宁可滚动也不要
    // 把课程名悄悄截断成省略号——老师需要一眼看全今天的课。
    return ClipRect(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        child: Row(children: children),
      ),
    );
  }
}

/// 非当前的课程：只有文字，不起块。
class _CourseLabel extends StatelessWidget {
  const _CourseLabel({required this.name, required this.scale});

  final String name;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        name,
        style: TextStyle(
          fontSize: 15 * scale,
          color: DesktopBarPalette.idleText,
        ),
      ),
    );
  }
}


/// 当前时段块（图一「课间休息 -2min」/ 图六「数学 -40min」）+ 底部进度条。
class _ActiveChip extends StatelessWidget {
  const _ActiveChip({
    super.key,
    required this.title,
    required this.remaining,
    required this.progress,
    required this.isBreak,
    required this.scale,
  });

  final String title;

  /// 已是最终文案（如「-40min」），格式化在时间线服务里统一处理。
  final String remaining;
  final double progress;
  final bool isBreak;
  final double scale;

  @override
  Widget build(BuildContext context) {
    // 进度条按 1 秒线性推进：状态每秒 tick 一次，动画正好把两次 tick 之间的
    // 跳变抹平，看起来是连续流动的。
    final duration = AppMotion.resolve(context, const Duration(seconds: 1));

    return AnimatedContainer(
      duration: AppMotion.resolve(context, AppMotion.fast),
      curve: AppMotion.curve,
      decoration: BoxDecoration(
        color: isBreak
            ? DesktopBarPalette.activeBreakChip
            : DesktopBarPalette.activeChip,
        borderRadius: BorderRadius.circular(4 * scale),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: DesktopBarMetrics.chipPadding * scale,
        vertical: 2 * scale,
      ),
      // 进度条用 Stack + Positioned 铺在块底：块宽由文字内容决定（桌面条里的
      // 课程块宽度是内容宽度），而 AnimatedFractionallySizedBox 需要一个确定
      // 的宽度才能按比例填充；Positioned(left/right: 0) 正好在块自身宽度确定后
      // 再按块宽拉满，既不用测量文字，也不会出现「无限宽度」的布局报错。
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 16 * scale,
                  fontWeight: FontWeight.bold,
                  color: DesktopBarPalette.activeText,
                ),
              ),
              SizedBox(width: 6 * scale),
              Text(
                remaining,
                style: TextStyle(
                  fontSize: 13 * scale,
                  color: const Color(0xFF9AA6B8),
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: DesktopBarMetrics.progressThickness * scale,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                DesktopBarMetrics.progressThickness,
              ),
              child: AnimatedFractionallySizedBox(
                duration: duration,
                curve: Curves.linear,
                alignment: Alignment.centerLeft,
                widthFactor: progress.clamp(0.0, 1.0),
                child: const ColoredBox(color: DesktopBarPalette.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
