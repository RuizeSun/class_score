import 'package:class_score/models/desktop_bar_style.dart';
import 'package:class_score/models/desktop_schedule_state.dart';
import 'package:class_score/providers/desktop_schedule_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定日期，避免用例随真实“今天”漂移。
final DateTime _day = DateTime(2026, 9, 23);

List<Map<String, dynamic>> get _courses => [
  {
    'weekday': _day.weekday,
    'course_name': '数学',
    'start_time': '08:00',
    'end_time': '08:40',
  },
  {
    'weekday': _day.weekday,
    'course_name': '英语',
    'start_time': '09:00',
    'end_time': '09:40',
  },
];

DateTime _at(int hour, int minute, [int second = 0]) =>
    DateTime(_day.year, _day.month, _day.day, hour, minute, second);

void main() {
  group('桌面课表状态推进', () {
    late DesktopScheduleProvider provider;

    setUp(() {
      // 只测「课表 → 状态」这条纯逻辑链路：不调用 init()，因此不访问数据库。
      provider = DesktopScheduleProvider();
    });

    tearDown(() => provider.dispose());

    test('课表推入后按时间得到对应阶段', () {
      provider.updateSchedules(_courses, const [], now: _at(8, 20));
      expect(provider.state.phase, DesktopSchedulePhase.inClass);
      expect(provider.state.currentSlot!.courseName, '数学');

      provider.updateSchedules(_courses, const [], now: _at(8, 42));
      expect(provider.state.phase, DesktopSchedulePhase.breakTime);

      provider.updateSchedules(_courses, const [], now: _at(8, 57));
      expect(provider.state.phase, DesktopSchedulePhase.preAlert);
    });

    test('图三 / 图四按设置的间隔交替（默认 4 秒）', () {
      provider.updateSchedules(_courses, const [], now: _at(8, 57, 2));
      expect(provider.state.phase, DesktopSchedulePhase.preCountdown);
      // 前 4 秒显示倒计时明细（图三）
      expect(provider.showPreparationHint, isFalse);

      // 第 4-8 秒切到准备提醒（图四）
      provider.updateSchedules(_courses, const [], now: _at(8, 57, 6));
      expect(provider.showPreparationHint, isTrue);
    });

    test('非倒计时阶段不做交替', () {
      provider.updateSchedules(_courses, const [], now: _at(8, 20));
      expect(provider.showPreparationHint, isFalse);
    });

    test('默认配置与空数据下的推送内容可用', () {
      provider.updateSchedules(const [], const [], now: _at(8, 20));

      expect(provider.state.phase, DesktopSchedulePhase.restDay);
      expect(provider.enabled, isFalse);
      expect(provider.position.name, 'top');
      expect(provider.layer.name, 'desktop');
      expect(provider.clickThrough, isTrue);
      expect(provider.preClassAlertMinutes, 3);

      // 未设置城市 / 未取到天气时不展示天气块
      expect(provider.weatherLabel, isNull);

      final payload = provider.toBarPayload();
      expect(payload['weather_label'], isNull);
      expect(payload['show_preparation_hint'], isFalse);
      expect(payload['state']['phase'], DesktopSchedulePhase.restDay.name);
      expect(payload['state']['slots'], isEmpty);
      // 外观参数随内容一起下发（浮窗据此调原生通道设置窗口样式）
      expect(payload['position'], 'top');
      expect(payload['layer'], 'desktop');
      expect(payload['click_through'], isTrue);
      expect(payload['scale'], 1.0);
    });

    test('显示位置：三个居中锚点，默认顶部居中（name 就是原生比对的锚点）', () {
      // 原生侧（desktop_bar_channel.cpp）按这些字符串决定垂直落点，
      // 三者都是水平居中，桌面左侧的快捷方式不会被挡住。
      expect(
        DesktopBarPosition.values.map((value) => value.name),
        ['top', 'upperCenter', 'bottom'],
      );
      expect(
        DesktopBarPosition.values.map((value) => value.label),
        ['顶部居中', '中央偏上', '底部居中'],
      );
      expect(provider.position, DesktopBarPosition.top);
      expect(provider.toBarPayload()['position'], 'top');
    });
  });
}
