import 'package:class_score/models/desktop_schedule_state.dart';
import 'package:class_score/models/weather_snapshot.dart';
import 'package:class_score/services/schedule_timeline_service.dart';
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

/// 以桌面尺寸渲染桌面条（宽度铺满窗口，与浮窗实际形态一致）。
Future<void> _pumpBar(
  WidgetTester tester,
  DesktopScheduleState state, {
  String? weatherLabel = '28℃',
  bool showPreparationHint = false,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
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

  testWidgets('课间休息（图一）：高亮块显示「课间休息」，落在下一节课的位置上', (tester) async {
    await _pumpBar(tester, _stateAt(8, 42));

    expect(find.text('课间休息'), findsOneWidget);
    expect(find.text('-18min'), findsOneWidget);
    // 已结束的课程仍然列出；下一节课的位置由「课间休息」块占据
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('英语'), findsNothing);
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

  testWidgets('1280 宽度下缩放后条高与字号同步变化，且不溢出', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: DesktopScheduleWidget(
              state: _stateAt(8, 20),
              weatherLabel: '28℃',
              weatherKind: WeatherKind.partlyCloudy,
              scale: 1.4,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final barSize = tester.getSize(find.byType(DesktopScheduleWidget));
    expect(barSize.height, closeTo(52 * 1.4, 0.01));
    expect(barSize.width, 1280);
    expect(tester.takeException(), isNull);
  });
}
