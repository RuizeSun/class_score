import 'package:class_score/models/group.dart';
import 'package:class_score/pages/analysis/statistics_page.dart';
import 'package:class_score/providers/group_provider.dart';
import 'package:class_score/providers/score_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 仅提供内存数据的 Provider，避免测试中访问数据库。

class _FakeScoreProvider extends ScoreProvider {
  _FakeScoreProvider({
    List<Map<String, dynamic>> students = const [],
    List<Map<String, dynamic>> groups = const [],
    int? filterGroupId,
  }) : _students = students,
       _groups = groups,
       _filterGroupId = filterGroupId;

  final List<Map<String, dynamic>> _students;
  final List<Map<String, dynamic>> _groups;
  int? _filterGroupId;

  @override
  List<Map<String, dynamic>> get studentTotalScores => _students;

  @override
  List<Map<String, dynamic>> get groupTotalScores => _groups;

  @override
  int? get filterGroupId => _filterGroupId;

  @override
  Future<void> loadStatistics({int? groupId}) async {
    _filterGroupId = groupId;
    notifyListeners();
  }
}

class _FakeGroupProvider extends GroupProvider {
  _FakeGroupProvider(this._groups);

  final List<Group> _groups;

  @override
  List<Group> get groups => _groups;

  @override
  Future<void> loadGroups() async {}
}

const List<Map<String, dynamic>> _students = [
  {
    'id': 11,
    'name': '张三',
    'student_number': '001',
    'group_name': '甲组',
    'total_score': 5.0,
  },
];

final List<Group> _groups = [Group(id: 1, name: '第一组')];

const List<Map<String, dynamic>> _groupScores = [
  {'id': 1, 'name': '第一组', 'total_score': 12.0, 'member_count': 4},
];

Widget _buildView({
  required ScoreProvider scoreProvider,
  required GroupProvider groupProvider,
  void Function(String targetType, int? targetId, String name)? onOpenAnalysis,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<ScoreProvider>.value(value: scoreProvider),
      ChangeNotifierProvider<GroupProvider>.value(value: groupProvider),
    ],
    child: MaterialApp(
      home: Scaffold(body: StatisticsView(onOpenAnalysis: onOpenAnalysis)),
    ),
  );
}

void main() {
  testWidgets('统计报表：高级查询与班级图表分析位于切换按钮同行', (tester) async {
    _useDesktopViewport(tester);
    final calls = <String>[];

    await tester.pumpWidget(
      _buildView(
        scoreProvider: _FakeScoreProvider(
          students: _students,
          groups: _groupScores,
        ),
        groupProvider: _FakeGroupProvider(_groups),
        onOpenAnalysis: (targetType, targetId, name) =>
            calls.add('$targetType/$targetId/$name'),
      ),
    );
    await tester.pumpAndSettle();

    // 同一行：按钮文字中心与切换按钮中心垂直对齐
    final segmentCenter = tester
        .getCenter(find.byType(SegmentedButton<bool>))
        .dy;
    expect(
      (tester.getCenter(find.text('高级查询')).dy - segmentCenter).abs(),
      lessThan(2.0),
      reason: '高级查询应与学生/小组切换同行',
    );
    expect(
      (tester.getCenter(find.text('班级图表分析')).dy - segmentCenter).abs(),
      lessThan(2.0),
      reason: '班级图表分析应与学生/小组切换同行',
    );

    // 学生模式：打开班级（全部学生）图表分析
    await tester.tap(find.text('班级图表分析'));
    await tester.pumpAndSettle();
    expect(calls, ['student/null/班级']);

    // 小组模式（等效全部小组）：同样提供入口
    calls.clear();
    await tester.tap(find.text('小组'));
    await tester.pumpAndSettle();
    expect(find.text('班级图表分析'), findsOneWidget);
    await tester.tap(find.text('班级图表分析'));
    await tester.pumpAndSettle();
    expect(calls, ['group/null/班级']);

    expect(tester.takeException(), isNull);
  });

  testWidgets('统计报表：点击学生或小组行均跳转对应图表分析', (tester) async {
    _useDesktopViewport(tester);
    final opens = <String>[];

    await tester.pumpWidget(
      _buildView(
        scoreProvider: _FakeScoreProvider(
          students: _students,
          groups: _groupScores,
        ),
        groupProvider: _FakeGroupProvider(_groups),
        onOpenAnalysis: (targetType, targetId, name) =>
            opens.add('$targetType/$targetId/$name'),
      ),
    );
    await tester.pumpAndSettle();

    // 学生行 → 该学生图表分析
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(opens, ['student/11/张三']);

    // 小组行 → 该小组图表分析（与学生行一致，不再跳转记录管理）
    await tester.tap(find.text('小组'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看评分记录'), findsNothing);
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(opens, ['student/11/张三', 'group/1/第一组']);

    expect(tester.takeException(), isNull);
  });

  testWidgets('统计报表：筛选具体小组后隐藏班级图表分析入口', (tester) async {
    _useDesktopViewport(tester);

    await tester.pumpWidget(
      _buildView(
        scoreProvider: _FakeScoreProvider(
          students: _students,
          groups: _groupScores,
        ),
        groupProvider: _FakeGroupProvider(_groups),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('班级图表分析'), findsOneWidget);

    // 选择具体小组后不再提供班级入口
    await tester.tap(find.text('全部小组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第一组').last);
    await tester.pumpAndSettle();

    expect(find.text('班级图表分析'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('查询页：TabBar 不再包含独立「图表分析」入口', (tester) async {
    _useDesktopViewport(tester);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ScoreProvider>.value(
            value: _FakeScoreProvider(
              students: _students,
              groups: _groupScores,
            ),
          ),
          ChangeNotifierProvider<GroupProvider>.value(
            value: _FakeGroupProvider(_groups),
          ),
        ],
        child: const MaterialApp(home: StatisticsAnalysisPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Tab), findsNWidgets(2));
    expect(find.text('统计报表'), findsOneWidget);
    expect(find.text('记录管理'), findsOneWidget);
    expect(find.text('图表分析'), findsNothing);

    expect(tester.takeException(), isNull);
  });
}

void _useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
