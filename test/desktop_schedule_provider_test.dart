import 'package:class_score/models/desktop_ball_style.dart';
import 'package:class_score/models/desktop_bar_style.dart';
import 'package:class_score/models/desktop_schedule_state.dart';
import 'package:class_score/providers/desktop_schedule_provider.dart';
import 'package:class_score/widgets/desktop_schedule/desktop_schedule_common.dart';
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
      // 悬浮球默认开着：让位参数随内容一起下发（原生据此把胶囊左移半个让位）
      expect(payload['ball_gap'], DesktopBarMetrics.ballGap);
      expect(payload['ball_ratio'], closeTo(defaultBallSizeRatio, 1e-9));
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

  group('双外观（桌面态 / 有程序在前台时）', () {
    late DesktopScheduleProvider provider;

    setUp(() {
      // 与上组同约定：不调 init()，只验证内存默认值与推送内容。
      provider = DesktopScheduleProvider();
    });

    tearDown(() => provider.dispose());

    test('默认关闭；前台态默认置顶，其余默认值与桌面态一致', () {
      // 开关默认关：老用户行为完全不变。
      expect(provider.foregroundEnabled, isFalse);
      expect(provider.foregroundPosition, DesktopBarPosition.top);
      // 前台态默认置顶：程序盖在桌面上时，桌面级胶囊会被完全挡住，
      // 功能看起来就像坏了。
      expect(provider.foregroundLayer, DesktopBarLayer.topMost);
      expect(provider.foregroundClickThrough, isTrue);
      expect(provider.foregroundOpacity, closeTo(0.92, 1e-9));
      expect(provider.foregroundScale, closeTo(1.0, 1e-9));

      final payload = provider.toBarPayload();
      expect(payload['foreground_enabled'], isFalse);
      expect(payload['foreground_position'], 'top');
      expect(payload['foreground_layer'], 'topMost');
      expect(payload['foreground_click_through'], isTrue);
      expect(payload['foreground_opacity'], closeTo(0.92, 1e-9));
      expect(payload['foreground_scale'], closeTo(1.0, 1e-9));

      // 桌面态字段（老键名）语义不变：仍是「无程序遮挡时」的外观。
      expect(payload['position'], 'top');
      expect(payload['layer'], 'desktop');
      expect(payload['scale'], 1.0);
    });

    test('pickDesktopBarAppearance：开关 × 前台态四组合', () {
      const desktop = DesktopBarAppearance(
        position: DesktopBarPosition.top,
        layer: DesktopBarLayer.desktop,
        clickThrough: true,
        opacity: 0.92,
        scale: 1.0,
      );
      const foreground = DesktopBarAppearance(
        position: DesktopBarPosition.bottom,
        layer: DesktopBarLayer.topMost,
        clickThrough: false,
        opacity: 0.6,
        scale: 0.8,
      );

      DesktopBarAppearance pick({required bool enabled, required bool active}) =>
          pickDesktopBarAppearance(
            foregroundEnabled: enabled,
            foregroundActive: active,
            desktop: desktop,
            foreground: foreground,
          );

      // 开关关闭：无论前台与否都用桌面态（same 断言返回的是同一实例）
      expect(pick(enabled: false, active: false), same(desktop));
      expect(pick(enabled: false, active: true), same(desktop));
      // 开关开启：只有「确实在前台」才切到前台态
      expect(pick(enabled: true, active: false), same(desktop));
      expect(pick(enabled: true, active: true), same(foreground));
    });

    test('shouldAnimateDesktopBarSwitch：仅「已应用 + 前台态翻转 + 外观有变」才播切换动画', () {
      bool animate({
        bool applied = true,
        bool flipped = true,
        bool changed = true,
      }) => shouldAnimateDesktopBarSwitch(
        alreadyApplied: applied,
        foregroundFlipped: flipped,
        appearanceChanged: changed,
      );

      // 三条件齐备：桌面态 ↔ 前台态交叉淡化
      expect(animate(), isTrue);
      // 首次应用没有「旧外观」可淡出（调用方单独淡入）
      expect(animate(applied: false), isFalse);
      // 设置页改参数 / 拖滑块：前台标记没翻转，直接生效避免连续闪烁
      expect(animate(flipped: false), isFalse);
      // 两套外观配得完全相同：原地淡出再淡入只会白闪一下
      expect(animate(changed: false), isFalse);
    });
  });

  group('桌面悬浮球', () {
    late DesktopScheduleProvider provider;

    setUp(() {
      // 同约定：不调 init()，只验证内存默认值与派生值。
      provider = DesktopScheduleProvider();
    });

    tearDown(() => provider.dispose());

    test('默认开启、大小 85%，停在屏幕右上角（偏移为 0）', () {
      expect(provider.ballEnabled, isTrue);
      expect(provider.ballSizeRatio, closeTo(defaultBallSizeRatio, 1e-9));
      expect(provider.ballOffsetX, 0);
      expect(provider.ballOffsetY, 0);
      // 无课表时的默认落点留白与胶囊顶部留白共用一套值
      expect(provider.ballMargin, DesktopBarMetrics.screenMargin);
    });

    test('球的基准高度跟随「整体缩放」，默认等于胶囊高度', () {
      expect(
        provider.scaledCapsuleHeight,
        closeTo(DesktopBarMetrics.height, 1e-9),
      );
      // 默认球径 ≈ 44px（52 × 0.85）：比胶囊略小一圈，不会压住胶囊两端的圆弧
      expect(
        provider.scaledCapsuleHeight * provider.ballSizeRatio,
        closeTo(DesktopBarMetrics.height * defaultBallSizeRatio, 1e-9),
      );
    });
  });
}
