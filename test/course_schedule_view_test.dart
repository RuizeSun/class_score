import 'package:class_score/pages/settings/course_schedule_management.dart';
import 'package:class_score/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 仅提供内存课程表数据的 AuthProvider，避免测试中访问数据库。
class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._schedules);

  final List<Map<String, dynamic>> _schedules;

  @override
  List<Map<String, dynamic>> get courseSchedules => _schedules;
}

Widget _buildView(AuthProvider provider) {
  return MaterialApp(
    home: Scaffold(
      body: ChangeNotifierProvider<AuthProvider>.value(
        value: provider,
        child: CourseScheduleManagementView(
          onShowCourseDialog: ({Map<String, dynamic>? schedule}) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('网格视图渲染课程并按星期分列', (tester) async {
    final provider = _FakeAuthProvider([
      {
        'id': 1,
        'weekday': 1,
        'course_name': '数学',
        'start_time': '08:00',
        'end_time': '09:40',
      },
      {
        'id': 2,
        'weekday': 3,
        'course_name': '英语',
        'start_time': '10:00',
        'end_time': '11:40',
      },
    ]);

    await tester.pumpWidget(_buildView(provider));
    await tester.pumpAndSettle();

    expect(find.text('数学'), findsOneWidget);
    expect(find.text('英语'), findsOneWidget);
    expect(find.text('08:00'), findsOneWidget);
    expect(find.text('周一'), findsOneWidget);
    expect(find.text('周日'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换到表格视图后行内可直接编辑', (tester) async {
    final provider = _FakeAuthProvider([
      {
        'id': 1,
        'weekday': 1,
        'course_name': '数学',
        'start_time': '08:00',
        'end_time': '09:40',
      },
    ]);

    await tester.pumpWidget(_buildView(provider));
    await tester.pumpAndSettle();

    await tester.tap(find.text('表格'));
    await tester.pumpAndSettle();

    // 表头与输入框提示都可能出现"课程名称"
    expect(find.text('课程名称'), findsWidgets);
    expect(find.widgetWithText(TextField, '数学'), findsOneWidget);
    expect(find.widgetWithText(TextField, '08:00'), findsOneWidget);
    expect(find.text('添加一行'), findsOneWidget);

    // 新增一行后应出现未保存提示与保存按钮
    await tester.tap(find.text('添加一行'));
    await tester.pumpAndSettle();

    expect(find.textContaining('未保存'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('1280x720 含侧边栏时网格与表格视图均无溢出', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = _FakeAuthProvider([
      for (int d = 1; d <= 5; d++)
        {
          'id': d,
          'weekday': d,
          'course_name': '课程$d',
          'start_time': '08:00',
          'end_time': '09:40',
        },
      {
        'id': 6,
        'weekday': 2,
        'course_name': '物理',
        'start_time': '10:00',
        'end_time': '11:40',
      },
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 260, child: ColoredBox(color: Colors.black12)),
              const VerticalDivider(width: 1),
              Expanded(
                child: ChangeNotifierProvider<AuthProvider>.value(
                  value: provider,
                  child: CourseScheduleManagementView(
                    onShowCourseDialog: ({Map<String, dynamic>? schedule}) {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('课程1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('表格'));
    await tester.pumpAndSettle();

    expect(find.text('添加一行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无数据时网格视图显示空状态', (tester) async {
    final provider = _FakeAuthProvider([]);

    await tester.pumpWidget(_buildView(provider));
    await tester.pumpAndSettle();

    expect(find.text('暂无课程安排'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
