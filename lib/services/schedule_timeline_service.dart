import '../models/desktop_schedule_state.dart';
import '../models/schedule_adjustment.dart';
import '../providers/auth_provider.dart';

/// 桌面课表时间线：把「课表数据 + 当前时间」翻译成桌面条要显示的状态。
///
/// 这里刻意做成纯函数（不读数据库、不起定时器、不碰 UI），因为桌面条的规则
/// 分支很多（上课中 / 课间 / 首节课前 / 放学后 / 无课日 / 临近上课 / 倒计时），
/// 全部靠时间判定，只有抽出来才能用单测覆盖边界（正好打铃、刚好 3 分钟前等）。
class ScheduleTimelineService {
  ScheduleTimelineService._();

  /// 临近上课提醒的默认提前量（默认 3 分钟，可设置）。
  static const Duration defaultPreClassAlert = Duration(minutes: 3);

  /// 图二 / 图五两张横幅的默认显示时长。
  static const Duration defaultNoticeDuration = Duration(seconds: 2);

  /// 构建某天的课程时间线（按开始时间升序）。
  ///
  /// [effectiveWeekday] 为 null 表示当天无课（调休放假），此时返回空列表；
  /// 时间格式非法的记录会被跳过，避免一条脏数据让整个桌面条失效。
  static List<ScheduleSlot> buildTimeline(
    List<Map<String, dynamic>> courseSchedules, {
    required int? effectiveWeekday,
    required DateTime day,
  }) {
    if (effectiveWeekday == null) return const [];

    final slots = <ScheduleSlot>[];
    for (final schedule in courseSchedules) {
      if ((schedule['weekday'] as int?) != effectiveWeekday) continue;

      final start = parseTimeOfDay(schedule['start_time'] as String?, day);
      final end = parseTimeOfDay(schedule['end_time'] as String?, day);
      if (start == null || end == null || !end.isAfter(start)) continue;

      slots.add(
        ScheduleSlot(
          courseName: (schedule['course_name'] as String?) ?? '',
          start: start,
          end: end,
        ),
      );
    }

    slots.sort((a, b) => a.start.compareTo(b.start));
    return slots;
  }

  /// 求解 [now] 时刻的展示状态。
  ///
  /// 规则（对应六张图）：
  /// - 正在上课：图六常态条，状态块为课程 + 剩余分钟；
  /// - 两节课之间：图一常态条，状态块为「课间休息 -Nmin」；
  /// - 距下节课开始不足 [preClassAlert]：先播 [noticeDuration] 的「即将上课」
  ///   横幅（图二），再进入倒计时（图三 ↔ 图四），正式上课瞬间播「上课」
  ///   横幅（图五）后回到常态条；
  /// - 下课不提示：课程结束时刻直接回到课间休息常态条。
  static DesktopScheduleState resolve({
    required List<Map<String, dynamic>> courseSchedules,
    required DateTime now,
    List<Map<String, dynamic>> adjustments = const [],
    Duration preClassAlert = defaultPreClassAlert,
    Duration noticeDuration = defaultNoticeDuration,
  }) {
    final weekday = ScheduleAdjustment.effectiveWeekdayFor(adjustments, now);
    final slots = buildTimeline(
      courseSchedules,
      effectiveWeekday: weekday,
      day: now,
    );

    if (slots.isEmpty) {
      return DesktopScheduleState(
        phase: DesktopSchedulePhase.restDay,
        slots: slots,
        now: now,
      );
    }

    final current = _slotContaining(slots, now);
    if (current != null) {
      final elapsed = now.difference(current.start);
      if (elapsed < noticeDuration) {
        // 图五：正式上课提示（进度条区间 = 横幅自身的显示时长）
        return DesktopScheduleState(
          phase: DesktopSchedulePhase.classNotice,
          slots: slots,
          currentSlot: current,
          nextSlot: _firstAfter(slots, now),
          now: now,
          phaseStart: current.start,
          phaseEnd: current.start.add(noticeDuration),
        );
      }
      // 图六：上课中
      return DesktopScheduleState(
        phase: DesktopSchedulePhase.inClass,
        slots: slots,
        currentSlot: current,
        nextSlot: _firstAfter(slots, now),
        now: now,
        phaseStart: current.start,
        phaseEnd: current.end,
      );
    }

    final next = _firstAfter(slots, now);
    if (next == null) {
      return DesktopScheduleState(
        phase: DesktopSchedulePhase.afterLast,
        slots: slots,
        now: now,
      );
    }

    final windowStart = next.start.subtract(preClassAlert);
    if (!now.isBefore(windowStart)) {
      final elapsed = now.difference(windowStart);
      return DesktopScheduleState(
        phase: elapsed < noticeDuration
            ? DesktopSchedulePhase.preAlert
            : DesktopSchedulePhase.preCountdown,
        slots: slots,
        nextSlot: next,
        now: now,
        // 进度条区间覆盖整个提醒窗口，于是背景填充比例就是「已等待 / 总等待」
        phaseStart: windowStart,
        phaseEnd: next.start,
      );
    }

    final previous = _lastBefore(slots, now);
    if (previous == null) {
      // 首节课前，且距离上课还很远：不显示状态块
      return DesktopScheduleState(
        phase: DesktopSchedulePhase.beforeFirst,
        slots: slots,
        nextSlot: next,
        now: now,
      );
    }

    // 图一：课间休息
    return DesktopScheduleState(
      phase: DesktopSchedulePhase.breakTime,
      slots: slots,
      nextSlot: next,
      now: now,
      phaseStart: previous.end,
      phaseEnd: next.start,
    );
  }

  /// 状态块里的剩余时间（图一「-2min」/ 图六「-40min」）。
  ///
  /// 按分钟向上取整、最少 1 分钟：避免出现「-0min」这种读起来像已上课的文案。
  static String formatChipRemaining(Duration remaining) {
    final minutes = (remaining.inSeconds / 60).ceil().clamp(1, 24 * 60);
    return '-${minutes}min';
  }

  /// 倒计时文案（图三「距上课还剩 53 秒」）。
  static String formatCountdown(Duration remaining) {
    if (remaining.inSeconds < 60) {
      return '${remaining.inSeconds.clamp(0, 59)} 秒';
    }
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '$minutes 分 $seconds 秒';
  }

  /// 解析「HH:mm」（兼容历史数据的「8:0」等写法）为当天的时刻。
  static DateTime? parseTimeOfDay(String? time, DateTime day) {
    final trimmed = time?.trim() ?? '';
    if (trimmed.isEmpty) return null;

    final normalized = AuthProvider.normalizeTime(trimmed);
    final parts = normalized.split(':');
    if (parts.length != 2) return null;

    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

    return DateTime(day.year, day.month, day.day, hour, minute);
  }

  static ScheduleSlot? _slotContaining(List<ScheduleSlot> slots, DateTime now) {
    for (final slot in slots) {
      if (!now.isBefore(slot.start) && now.isBefore(slot.end)) return slot;
    }
    return null;
  }

  static ScheduleSlot? _firstAfter(List<ScheduleSlot> slots, DateTime now) {
    for (final slot in slots) {
      if (slot.start.isAfter(now)) return slot;
    }
    return null;
  }

  static ScheduleSlot? _lastBefore(List<ScheduleSlot> slots, DateTime now) {
    ScheduleSlot? found;
    for (final slot in slots) {
      if (!slot.end.isAfter(now)) found = slot;
    }
    return found;
  }
}
