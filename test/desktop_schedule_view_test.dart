import 'package:class_score/models/desktop_schedule_state.dart';
import 'package:class_score/models/weather_snapshot.dart';
import 'package:class_score/services/schedule_timeline_service.dart';
import 'package:class_score/widgets/desktop_schedule/desktop_schedule_common.dart';
import 'package:class_score/widgets/desktop_schedule/desktop_schedule_widget.dart';
import 'package:flutter/material.dart';
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

DesktopScheduleState _stateAt(int hour, int minute, [int second = 0]) =>
    ScheduleTimelineService.resolve(
      courseSchedules: _courses,
      now: _at(hour, minute, second),
    );

/// 以浮窗的真实形态渲染：1280 宽的屏幕 + 按缩放计算的胶囊宽
/// （原生窗口宽 = [DesktopBarMetrics.capsuleWidth] × 缩放）。
///
/// 浮窗宽度由原生设定（见 `windows/runner/desktop_bar_channel.cpp`），这里用同一个
/// 公式模拟，避免「测试里 1280 宽不溢出、实际胶囊里却挤爆」这种假绿灯。
Future<void> _pumpBar(
  WidgetTester tester,
  DesktopScheduleState state, {
  String? weatherLabel = '28℃',
  bool showPreparationHint = false,
  double scale = 1.0,
  double? width,
  double viewportWidth = 1280,
}) async {
  tester.view.physicalSize = Size(viewportWidth, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: DesktopScheduleWidget(
            state: state,
            weatherLabel: weatherLabel,
            weatherKind: WeatherKind.partlyCloudy,
            showPreparationHint: showPreparationHint,
            scale: scale,
            width: width ?? DesktopBarMetrics.capsuleWidth * scale,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('常态条（图六）：天气 + 课程列表 + 当前课程剩余时间', (tester) async {
    await _pumpBar(tester, _stateAt(8, 20));

    expect(find.text('28℃'), findsOneWidget);
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('-20min'), findsOneWidget);
    expect(find.text('英语'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('课间休息（图一）：进度块插在下一节课之前，不顶掉下节课的名字', (tester) async {
    await _pumpBar(tester, _stateAt(8, 42));

    expect(find.text('课间休息'), findsOneWidget);
    expect(find.text('-18min'), findsOneWidget);
    // 上节课与下节课都照常列出，课间进度块只插在两者之间
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('英语'), findsOneWidget);
    final mathX = tester.getTopLeft(find.text('数学')).dx;
    final breakX = tester.getTopLeft(find.text('课间休息')).dx;
    final englishX = tester.getTopLeft(find.text('英语')).dx;
    expect(mathX, lessThan(breakX));
    expect(breakX, lessThan(englishX));
    expect(tester.takeException(), isNull);
  });

  testWidgets('无课日：只显示天气与「今日无课」', (tester) async {
    final state = ScheduleTimelineService.resolve(
      courseSchedules: _courses,
      adjustments: [
        {'date': '2026-09-23', 'weekday': 0},
      ],
      now: _at(8, 20),
    );

    await _pumpBar(tester, state);

    expect(find.text('28℃'), findsOneWidget);
    expect(find.text('今日无课'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('图二：临近上课时整条变为「即将上课」横幅', (tester) async {
    await _pumpBar(tester, _stateAt(8, 57));

    expect(find.text('即将上课'), findsOneWidget);
    expect(find.text('28℃'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('图三：倒计时明细（剩余时间 + 下节课与时间）', (tester) async {
    await _pumpBar(tester, _stateAt(8, 59, 7));

    expect(find.text('距上课还剩 '), findsOneWidget);
    expect(find.text('53 秒'), findsOneWidget);
    expect(find.text('下节课是：'), findsOneWidget);
    expect(find.text('英语'), findsOneWidget);
    expect(find.text('09:00-09:40'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('图四：与图三交替显示准备提醒，两图共用同一背景进度条', (tester) async {
    await _pumpBar(tester, _stateAt(8, 59, 7), showPreparationHint: true);

    expect(find.text('准备上课，请回到座位并保持安静，做好上课准备。'), findsOneWidget);
    expect(find.text('53 秒'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('图五：正式上课瞬间整条变为「上课」横幅', (tester) async {
    await _pumpBar(tester, _stateAt(9, 0));

    expect(find.text('上课'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('阶段切换走淡入淡出：旧外观退场、新外观进场', (tester) async {
    await _pumpBar(tester, _stateAt(8, 57));
    expect(find.text('即将上课'), findsOneWidget);

    // 切到上课中（图六）
    await _pumpBar(tester, _stateAt(8, 20));

    expect(find.text('即将上课'), findsNothing);
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('-20min'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('胶囊：固定宽度 + 两端半圆，缩放下宽高与圆角同步变化', (tester) async {
    await _pumpBar(tester, _stateAt(8, 20), scale: 1.4);

    final size = tester.getSize(find.byType(DesktopScheduleWidget));
    // 宽度是固定胶囊宽（720）× 缩放，而不是铺满 1280 的屏幕
    expect(size.width, closeTo(DesktopBarMetrics.capsuleWidth * 1.4, 0.01));
    expect(size.height, closeTo(DesktopBarMetrics.height * 1.4, 0.01));

    // 圆角半径 = 高度一半，两端才是半圆（与原生 CreateRoundRectRgn 一致）
    final radii = tester
        .widgetList<ClipRRect>(
          find.descendant(
            of: find.byType(DesktopScheduleWidget),
            matching: find.byType(ClipRRect),
          ),
        )
        .map((clip) => clip.borderRadius)
        .toList();
    expect(
      radii,
      contains(
        BorderRadius.circular(DesktopBarMetrics.capsuleRadius(1.4)),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏：胶囊收缩到视口宽，不溢出（原生同样会收缩窗口）', (tester) async {
    // 请求 1008 宽，但视口只有 600
    await _pumpBar(
      tester,
      _stateAt(8, 20),
      scale: 1.4,
      viewportWidth: 600,
    );

    final size = tester.getSize(find.byType(DesktopScheduleWidget));
    expect(size.width, closeTo(600, 0.01));
    expect(size.height, closeTo(DesktopBarMetrics.height * 1.4, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('三种外观都落在同一胶囊尺寸里（换阶段外形不跳）', (tester) async {
    // 常态条 → 蓝底横幅 → 倒计时
    for (final state in [_stateAt(8, 20), _stateAt(8, 57), _stateAt(8, 59, 7)]) {
      await _pumpBar(tester, state, scale: 1.2);

      final size = tester.getSize(find.byType(DesktopScheduleWidget));
      expect(size.width, closeTo(DesktopBarMetrics.capsuleWidth * 1.2, 0.01));
      expect(size.height, closeTo(DesktopBarMetrics.height * 1.2, 0.01));
      expect(tester.takeException(), isNull);
    }
  });
}
