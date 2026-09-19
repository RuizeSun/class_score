import 'package:class_score/models/schedule_adjustment.dart';
import 'package:class_score/pages/settings/course_schedule_management.dart';
import 'package:class_score/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 仅提供内存调休 / 课表数据的 AuthProvider，避免测试中访问数据库。
class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider({
    List<Map<String, dynamic>> schedules = const [],
    List<Map<String, dynamic>> adjustments = const [],
  }) : _schedules = schedules,
       _adjustments = adjustments;

  final List<Map<String, dynamic>> _schedules;
  final List<Map<String, dynamic>> _adjustments;

  /// 记录被写入 / 清除的调休，供断言使用。
  final List<({DateTime date, int weekday})> savedAdjustments = [];
  final List<DateTime> removedAdjustments = [];
  int clearExpiredCalls = 0;

  @override
  List<Map<String, dynamic>> get courseSchedules => _schedules;

  @override
  List<Map<String, dynamic>> get scheduleAdjustments => _adjustments;

  @override
  Future<void> setScheduleAdjustment(DateTime date, int weekday) async {
    savedAdjustments.add((date: date, weekday: weekday));
  }

  @override
  Future<void> removeScheduleAdjustment(DateTime date) async {
    removedAdjustments.add(date);
  }

  @override
  Future<int> clearExpiredAdjustments() async {
    clearExpiredCalls++;
    return 1;
  }
}

/// 周三有课、周五无课的一份课程表。
const List<Map<String, dynamic>> _kSchedules = [
  {
    'id': 1,
    'weekday': 3,
    'course_name': '数学',
    'start_time': '08:00',
    'end_time': '09:40',
  },
];

Widget _buildView(
  AuthProvider provider, {
  void Function({DateTime? date})? onShowAdjustmentDialog,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChangeNotifierProvider<AuthProvider>.value(
        value: provider,
        child: CourseScheduleManagementView(
          onShowCourseDialog: ({Map<String, dynamic>? schedule}) {},
          onShowAdjustmentDialog:
              onShowAdjustmentDialog ?? ({DateTime? date}) {},
        ),
      ),
    ),
  );
}

/// 打开「设置调休」对话框的测试宿主。
Widget _buildDialogHost(AuthProvider provider, DateTime date) {
  return MaterialApp(
    home: Scaffold(
      body: ChangeNotifierProvider<AuthProvider>.value(
        value: provider,
        child: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () =>
                  showScheduleAdjustmentDialog(context, date: date),
              child: const Text('打开调休设置'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('调休解析', () {
    test('无调休时按日期自身的星期', () {
      final date = DateTime(2026, 9, 19);
      expect(
        ScheduleAdjustment.effectiveWeekdayFor(const [], date),
        date.weekday,
      );
      expect(ScheduleAdjustment.findFor(const [], date), isNull);
      expect(ScheduleAdjustment.isRestDay(const [], date), isFalse);
    });

    test('调休后按目标星期的课表', () {
      final adjustments = [
        {'id': 1, 'date': '2026-09-19', 'weekday': 3, 'created_at': ''},
      ];
      final date = DateTime(2026, 9, 19);
      expect(ScheduleAdjustment.effectiveWeekdayFor(adjustments, date), 3);
      expect(ScheduleAdjustment.isRestDay(adjustments, date), isFalse);
      expect(ScheduleAdjustment.describeWeekday(3), '按周三课表');
      // 其他日期不受影响
      expect(
        ScheduleAdjustment.effectiveWeekdayFor(
          adjustments,
          DateTime(2026, 9, 20),
        ),
        DateTime(2026, 9, 20).weekday,
      );
    });

    test('调休为无课时生效星期为 null', () {
      final adjustments = [
        {
          'id': 1,
          'date': '2026-09-19',
          'weekday': ScheduleAdjustment.restWeekday,
          'created_at': '',
        },
      ];
      final date = DateTime(2026, 9, 19);
      expect(ScheduleAdjustment.effectiveWeekdayFor(adjustments, date), isNull);
      expect(ScheduleAdjustment.isRestDay(adjustments, date), isTrue);
      expect(
        ScheduleAdjustment.describeWeekday(ScheduleAdjustment.restWeekday),
        '无课（放假）',
      );
    });

    test('日期键补零且按周一为一周起点', () {
      expect(ScheduleAdjustment.dateKey(DateTime(2026, 9, 5)), '2026-09-05');
      expect(
        ScheduleAdjustment.startOfWeek(DateTime(2026, 9, 19)),
        DateTime(2026, 9, 14),
      );
      expect(
        ScheduleAdjustment.startOfWeek(DateTime(2026, 9, 14)).weekday,
        DateTime.monday,
      );
      expect(ScheduleAdjustment.formatMonthDay(DateTime(2026, 9, 5)), '9月5日');
      expect(
        ScheduleAdjustment.formatWeekRange(DateTime(2026, 9, 14)),
        '9月14日 - 9月20日',
      );
    });
  });

  group('课程表调休界面', () {
    testWidgets('网格视图在本周对应星期列标注调休', (tester) async {
      final saturday = ScheduleAdjustment.startOfWeek(
        DateTime.now(),
      ).add(const Duration(days: 5));
      final provider = _FakeAuthProvider(
        schedules: _kSchedules,
        adjustments: [
          {
            'id': 1,
            'date': ScheduleAdjustment.dateKey(saturday),
            'weekday': 3,
            'created_at': '',
          },
        ],
      );

      await tester.pumpWidget(_buildView(provider));
      await tester.pumpAndSettle();

      // 表头标注：本周调休 + 目标课表
      expect(
        find.text('本周调休 ${saturday.month}/${saturday.day}'),
        findsOneWidget,
      );
      expect(find.text('按周三课表'), findsOneWidget);
      // 提示条同步展示
      expect(find.text('本周调休：'), findsOneWidget);
      expect(find.textContaining('（周六）按周三课表'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无调休时不显示调休标注与提示条', (tester) async {
      await tester.pumpWidget(
        _buildView(_FakeAuthProvider(schedules: _kSchedules)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('本周调休'), findsNothing);
      expect(find.text('数学'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点击「设置调休」按钮触发回调', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _buildView(
          _FakeAuthProvider(schedules: _kSchedules),
          onShowAdjustmentDialog: ({DateTime? date}) => calls++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('设置调休'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('存在过期调休时可从工具栏清理', (tester) async {
      // 上周周一：已过期，不再参与本周标注
      final expired = ScheduleAdjustment.startOfWeek(
        DateTime.now(),
      ).subtract(const Duration(days: 7));
      final provider = _FakeAuthProvider(
        schedules: _kSchedules,
        adjustments: [
          {
            'id': 1,
            'date': ScheduleAdjustment.dateKey(expired),
            'weekday': 3,
            'created_at': '',
          },
        ],
      );

      await tester.pumpWidget(_buildView(provider));
      await tester.pumpAndSettle();

      expect(find.textContaining('本周调休'), findsNothing);
      expect(find.text('清理过期调休'), findsOneWidget);

      await tester.tap(find.text('清理过期调休'));
      await tester.pumpAndSettle();

      expect(provider.clearExpiredCalls, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('设置调休对话框', () {
    // 2026-09-19 为周六，属于 2026-09-14（周一）开始的那一周
    final targetDate = DateTime(2026, 9, 19);

    testWidgets('选择生效课表后确定写入调休', (tester) async {
      final provider = _FakeAuthProvider(schedules: _kSchedules);
      await tester.pumpWidget(_buildDialogHost(provider, targetDate));
      await tester.tap(find.text('打开调休设置'));
      await tester.pumpAndSettle();

      expect(find.text('设置调休'), findsOneWidget);
      expect(find.text('9月14日 - 9月20日'), findsOneWidget);

      // 打开下拉框并选择「按周三课表（1节）」
      await tester.tap(find.text('不调休（按日期自身课表）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('按周三课表（1节）').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(provider.savedAdjustments, hasLength(1));
      expect(provider.savedAdjustments.single.date, targetDate);
      expect(provider.savedAdjustments.single.weekday, 3);
      expect(find.text('设置调休'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未选择生效课表时给出校验提示', (tester) async {
      final provider = _FakeAuthProvider(schedules: _kSchedules);
      await tester.pumpWidget(_buildDialogHost(provider, targetDate));
      await tester.tap(find.text('打开调休设置'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.text('请选择该日按哪天的课表上课'), findsOneWidget);
      expect(provider.savedAdjustments, isEmpty);
      expect(provider.removedAdjustments, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已有调休时可清除该日设置', (tester) async {
      final provider = _FakeAuthProvider(
        schedules: _kSchedules,
        adjustments: [
          {
            'id': 1,
            'date': ScheduleAdjustment.dateKey(targetDate),
            'weekday': 3,
            'created_at': '',
          },
        ],
      );
      await tester.pumpWidget(_buildDialogHost(provider, targetDate));
      await tester.tap(find.text('打开调休设置'));
      await tester.pumpAndSettle();

      expect(find.textContaining('该日期已设置：按周三课表'), findsOneWidget);

      await tester.tap(find.text('清除该日调休'));
      await tester.pumpAndSettle();

      expect(provider.removedAdjustments, [targetDate]);
      expect(provider.savedAdjustments, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('1280x800 下对话框与调休标注均无溢出', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final provider = _FakeAuthProvider(schedules: _kSchedules);
      await tester.pumpWidget(_buildDialogHost(provider, targetDate));
      await tester.tap(find.text('打开调休设置'));
      await tester.pumpAndSettle();

      expect(find.text('设置调休'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_buildView(provider));
      await tester.pumpAndSettle();
      expect(find.text('设置调休'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
