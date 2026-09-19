/// 调休：临时把某个日期切换成课表中另一天的课程安排。
///
/// 调休只按“日期”生效，不会修改课表本身：
/// - [weekday] 为 1-7 时，该日期按对应星期的课表上课；
/// - [weekday] 为 [restWeekday]（0）时，该日期无课（放假）。
class ScheduleAdjustment {
  final int? id;

  /// 调休日期，格式 yyyy-MM-dd（同一天只允许一条记录）。
  final String date;
  final int weekday;
  final String createdAt;

  ScheduleAdjustment({
    this.id,
    required this.date,
    required this.weekday,
    String? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toIso8601String();

  /// 该日期无课（放假）时 weekday 的取值。
  static const int restWeekday = 0;

  /// 星期简称（1 = 周一 ... 7 = 周日），与课表 weekday 字段一致。
  static const Map<int, String> weekdayNames = {
    1: '周一',
    2: '周二',
    3: '周三',
    4: '周四',
    5: '周五',
    6: '周六',
    7: '周日',
  };

  static String weekdayName(int weekday) {
    if (weekday == restWeekday) return '无课';
    return weekdayNames[weekday] ?? '周$weekday';
  }

  /// 日期键：yyyy-MM-dd（用于数据库主键匹配与比较）。
  static String dateKey(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  static DateTime parseDateKey(String key) {
    final parts = key.split('-');
    return DateTime(
      int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 1970,
      int.tryParse(parts.length > 1 ? parts[1] : '') ?? 1,
      int.tryParse(parts.length > 2 ? parts[2] : '') ?? 1,
    );
  }

  /// 仅保留年月日，避免时间部分影响比较。
  static DateTime dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  /// 该日期所在周的周一（weekday = 1 对应周一）。
  static DateTime startOfWeek(DateTime date) {
    final day = dateOnly(date);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  /// 「9月19日」
  static String formatMonthDay(DateTime date) => '${date.month}月${date.day}日';

  /// 「2026年9月19日」
  static String formatFullDate(DateTime date) =>
      '${date.year}年${date.month}月${date.day}日';

  /// 「9月14日 - 9月20日」
  static String formatWeekRange(DateTime weekStart) {
    final start = dateOnly(weekStart);
    final end = start.add(const Duration(days: 6));
    return '${formatMonthDay(start)} - ${formatMonthDay(end)}';
  }

  /// 查找 [date] 当天的调休记录（没有则返回 null）。
  static Map<String, dynamic>? findFor(
    List<Map<String, dynamic>> adjustments,
    DateTime date,
  ) {
    final key = dateKey(date);
    for (final adjustment in adjustments) {
      if (adjustment['date'] == key) return adjustment;
    }
    return null;
  }

  /// [date] 当天是否被设置为无课（放假）。
  static bool isRestDay(List<Map<String, dynamic>> adjustments, DateTime date) {
    return findFor(adjustments, date)?['weekday'] == restWeekday;
  }

  /// [date] 当天实际生效的星期：
  /// - 无调休：返回日期自身的星期（1-7）；
  /// - 有调休：返回调休指定的星期，若为 [restWeekday] 则返回 null（当天无课）。
  static int? effectiveWeekdayFor(
    List<Map<String, dynamic>> adjustments,
    DateTime date,
  ) {
    final adjustment = findFor(adjustments, date);
    if (adjustment == null) return date.weekday;
    final weekday = (adjustment['weekday'] as int?) ?? date.weekday;
    return weekday == restWeekday ? null : weekday;
  }

  /// 调休说明文案，例如「按周三课表」「无课（放假）」。
  static String describeWeekday(int weekday) {
    if (weekday == restWeekday) return '无课（放假）';
    return '按${weekdayName(weekday)}课表';
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'date': date,
      'weekday': weekday,
      'created_at': createdAt,
    };
  }

  factory ScheduleAdjustment.fromMap(Map<String, dynamic> map) {
    return ScheduleAdjustment(
      id: map['id'] as int?,
      date: map['date'] as String,
      weekday: map['weekday'] as int,
      createdAt: map['created_at'] as String?,
    );
  }
}
