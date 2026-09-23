import 'package:class_score/models/desktop_schedule_state.dart';
import 'package:class_score/services/schedule_timeline_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试用的固定日期（避免用例随真实“今天”漂移）。
final DateTime _day = DateTime(2026, 9, 23);

/// 当天的星期（课表 weekday 字段使用 1-7）。
int get _weekday => _day.weekday;

Map<String, dynamic> _course(
  String name,
  String start,
  String end, {
  int? weekday,
}) => {
  'weekday': weekday ?? _weekday,
  'course_name': name,
  'start_time': start,
  'end_time': end,
};

/// 一天两节课：08:00-08:40 数学（课间 20 分钟）、09:00-09:40 英语。
List<Map<String, dynamic>> get _twoCourses => [
  _course('数学', '08:00', '08:40'),
  _course('英语', '09:00', '09:40'),
];

DateTime _at(int hour, int minute, [int second = 0]) =>
    DateTime(_day.year, _day.month, _day.day, hour, minute, second);

DesktopScheduleState _resolve(
  DateTime now, {
  List<Map<String, dynamic>>? courses,
  List<Map<String, dynamic>> adjustments = const [],
  Duration preClassAlert = ScheduleTimelineService.defaultPreClassAlert,
  Duration noticeDuration = ScheduleTimelineService.defaultNoticeDuration,
}) => ScheduleTimelineService.resolve(
  courseSchedules: courses ?? _twoCourses,
  adjustments: adjustments,
  now: now,
  preClassAlert: preClassAlert,
  noticeDuration: noticeDuration,
);

void main() {
  group('时间线构建', () {
    test('按开始时间排序，并只保留当天生效星期的课程', () {
      final slots = ScheduleTimelineService.buildTimeline([
        _course('英语', '09:00', '09:40'),
        _course('数学', '08:00', '08:40'),
        _course('别的天', '07:00', '07:40', weekday: _weekday % 7 + 1),
      ], effectiveWeekday: _weekday, day: _day);

      expect(slots.map((slot) => slot.courseName).toList(), ['数学', '英语']);
      expect(slots.first.timeRange, '08:00-08:40');
      expect(slots.first.duration, const Duration(minutes: 40));
    });

    test('无课日（生效星期为 null）返回空时间线', () {
      final slots = ScheduleTimelineService.buildTimeline(
        _twoCourses,
        effectiveWeekday: null,
        day: _day,
      );

      expect(slots, isEmpty);
    });

    test('时间格式非法或结束早于开始的脏数据被跳过', () {
      final slots = ScheduleTimelineService.buildTimeline([
        _course('数学', '08:00', '08:40'),
        _course('脏数据', '25:99', '26:00'),
        _course('倒挂', '10:00', '09:00'),
        _course('空时间', '', ''),
      ], effectiveWeekday: _weekday, day: _day);

      expect(slots.map((slot) => slot.courseName).toList(), ['数学']);
    });

    test('兼容历史数据里「8:0」这类时间写法', () {
      final slots = ScheduleTimelineService.buildTimeline([
        _course('数学', '8:0', '8:40'),
      ], effectiveWeekday: _weekday, day: _day);

      expect(slots.single.start, _at(8, 0));
      expect(slots.single.end, _at(8, 40));
    });
  });

  group('上课中（图六）', () {
    test('状态块为当前课程，剩余时间与进度按课程时长计算', () {
      final state = _resolve(_at(8, 20));

      expect(state.phase, DesktopSchedulePhase.inClass);
      expect(state.currentSlot!.courseName, '数学');
      expect(state.remaining, const Duration(minutes: 20));
      expect(state.progress, closeTo(0.5, 1e-9));
      expect(
        ScheduleTimelineService.formatChipRemaining(state.remaining),
        '-20min',
      );
    });

    test('剩余时间不足一分钟时向上取整为 1 分钟，不出现 -0min', () {
      final state = _resolve(_at(8, 39, 30));

      expect(state.phase, DesktopSchedulePhase.inClass);
      expect(
        ScheduleTimelineService.formatChipRemaining(state.remaining),
        '-1min',
      );
    });
  });

  group('课间休息（图一）', () {
    test('状态块显示课间剩余分钟，进度按整个课间计算', () {
      final state = _resolve(_at(8, 42));

      expect(state.phase, DesktopSchedulePhase.breakTime);
      expect(state.currentSlot, isNull);
      expect(state.nextSlot!.courseName, '英语');
      expect(state.remaining, const Duration(minutes: 18));
      expect(state.progress, closeTo(2 / 20, 1e-9));
      expect(
        ScheduleTimelineService.formatChipRemaining(state.remaining),
        '-18min',
      );
    });

    test('下课瞬间不提示，直接回到课间休息常态条', () {
      final state = _resolve(_at(8, 40));

      expect(state.phase, DesktopSchedulePhase.breakTime);
      expect(state.remaining, const Duration(minutes: 20));
    });
  });

  group('课前 / 课后 / 无课', () {
    test('首节课前较远时只显示课程列表，不给状态块', () {
      final state = _resolve(_at(7, 30));

      expect(state.phase, DesktopSchedulePhase.beforeFirst);
      expect(state.currentSlot, isNull);
      expect(state.nextSlot!.courseName, '数学');
      expect(state.progress, 0);
    });

    test('最后一节课结束后进入 afterLast', () {
      final state = _resolve(_at(10, 30));

      expect(state.phase, DesktopSchedulePhase.afterLast);
      expect(state.slots.length, 2);
    });

    test('调休放假当天为 restDay', () {
      final state = _resolve(
        _at(10, 30),
        adjustments: [
          {'date': '2026-09-23', 'weekday': 0},
        ],
      );

      expect(state.phase, DesktopSchedulePhase.restDay);
      expect(state.slots, isEmpty);
    });

    test('调休按其他星期的课表上课', () {
      final otherWeekday = _weekday == 7 ? 1 : _weekday + 1;
      final state = _resolve(
        _at(8, 20),
        courses: [_course('调休课', '08:00', '08:40', weekday: otherWeekday)],
        adjustments: [
          {'date': '2026-09-23', 'weekday': otherWeekday},
        ],
      );

      expect(state.phase, DesktopSchedulePhase.inClass);
      expect(state.currentSlot!.courseName, '调休课');
    });
  });

  group('临近上课：图二 → 图三/图四 → 图五 → 图六', () {
    test('提前提醒窗口内先播「即将上课」横幅', () {
      final state = _resolve(_at(8, 57));

      expect(state.phase, DesktopSchedulePhase.preAlert);
      expect(state.nextSlot!.courseName, '英语');
      expect(state.phaseTotal, const Duration(minutes: 3));
      expect(state.nextSlot!.timeRange, '09:00-09:40');
    });

    test('横幅播完后进入倒计时，文案与背景进度随时间推进', () {
      final state = _resolve(_at(8, 57, 2));

      expect(state.phase, DesktopSchedulePhase.preCountdown);
      expect(state.remaining, const Duration(seconds: 178));
      expect(
        ScheduleTimelineService.formatCountdown(state.remaining),
        '2 分 58 秒',
      );
      expect(state.progress, closeTo(2 / 180, 1e-9));

      final lastSecond = _resolve(_at(8, 59, 7));
      expect(lastSecond.phase, DesktopSchedulePhase.preCountdown);
      expect(
        ScheduleTimelineService.formatCountdown(lastSecond.remaining),
        '53 秒',
      );
    });

    test('正式上课瞬间播「上课」横幅，随后回到上课常态（图六）', () {
      final notice = _resolve(_at(9, 0));
      expect(notice.phase, DesktopSchedulePhase.classNotice);
      expect(notice.currentSlot!.courseName, '英语');

      final afterNotice = _resolve(_at(9, 0, 2));
      expect(afterNotice.phase, DesktopSchedulePhase.inClass);
      expect(afterNotice.progress, closeTo(2 / (40 * 60), 1e-9));
    });

    test('提前提醒时间可配置：设为 1 分钟时更晚才进入提示流程', () {
      final state = _resolve(
        _at(8, 57),
        preClassAlert: const Duration(minutes: 1),
      );

      expect(state.phase, DesktopSchedulePhase.breakTime);

      final alert = _resolve(
        _at(8, 59),
        preClassAlert: const Duration(minutes: 1),
      );
      expect(alert.phase, DesktopSchedulePhase.preAlert);
    });
  });

  group('文案与跨窗口快照', () {
    test('倒计时文案：不足 1 分钟只显示秒', () {
      expect(
        ScheduleTimelineService.formatCountdown(const Duration(seconds: 53)),
        '53 秒',
      );
      expect(ScheduleTimelineService.formatCountdown(Duration.zero), '0 秒');
      expect(
        ScheduleTimelineService.formatCountdown(const Duration(seconds: 125)),
        '2 分 5 秒',
      );
    });

    test('状态可序列化 / 反序列化后保持一致', () {
      final state = _resolve(_at(8, 42));
      final restored = DesktopScheduleState.fromJson(state.toJson());

      expect(restored.phase, state.phase);
      expect(restored.slots.length, state.slots.length);
      expect(restored.nextSlot!.courseName, '英语');
      expect(restored.phaseStart, state.phaseStart);
      expect(restored.phaseEnd, state.phaseEnd);
      expect(restored.remaining, state.remaining);
    });

    test('平台通道那种 `Map<Object?, Object?>` 嵌套也能解析', () {
      // StandardMethodCodec 解码后嵌套结构是 Map<Object?, Object?>，
      // 之前这里直接 `as Map<String, dynamic>` 会让浮窗解析崩掉。
      final raw = <Object?, Object?>{
        'phase': 'breakTime',
        'now': _at(8, 42).toIso8601String(),
        'phase_start': _at(8, 40).toIso8601String(),
        'phase_end': _at(9, 0).toIso8601String(),
        'slots': <Object?>[
          <Object?, Object?>{
            'course_name': '数学',
            'start': _at(8, 0).toIso8601String(),
            'end': _at(8, 40).toIso8601String(),
          },
        ],
        'next_slot': <Object?, Object?>{
          'course_name': '英语',
          'start': _at(9, 0).toIso8601String(),
          'end': _at(9, 40).toIso8601String(),
        },
      };

      final restored = DesktopScheduleState.fromJson(asStringKeyedMap(raw));

      expect(restored.phase, DesktopSchedulePhase.breakTime);
      expect(restored.slots.single.courseName, '数学');
      expect(restored.nextSlot!.courseName, '英语');
      expect(restored.nextSlot!.timeRange, '09:00-09:40');
    });
  });
}

