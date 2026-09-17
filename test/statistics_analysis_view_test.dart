import 'package:class_score/models/group.dart';
import 'package:class_score/models/score_item.dart';
import 'package:class_score/models/student.dart';
import 'package:class_score/pages/analysis/statistics_page.dart';
import 'package:class_score/providers/auth_provider.dart';
import 'package:class_score/providers/group_provider.dart';
import 'package:class_score/providers/personalization_provider.dart';
import 'package:class_score/providers/score_item_provider.dart';
import 'package:class_score/providers/score_provider.dart';
import 'package:class_score/providers/student_provider.dart';
import 'package:class_score/widgets/pane_header.dart';
import 'package:class_score/widgets/ranking_tile.dart';
import 'package:class_score/widgets/resizable_split_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 仅提供内存数据的 Provider，避免测试中访问数据库。

/// 一次 loadRecords 的调用参数（用于验证两栏联动）。
typedef _LoadCall = ({String? targetType, int? targetId, int? groupId});

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

  /// 记录每次 loadRecords 的参数，最后一条即当前筛选条件。
  final List<_LoadCall> loadCalls = [];

  @override
  List<Map<String, dynamic>> get studentTotalScores => _students;

  @override
  List<Map<String, dynamic>> get groupTotalScores => _groups;

  @override
  List<Map<String, dynamic>> get recordsWithName => const [];

  @override
  int? get filterGroupId => _filterGroupId;

  @override
  Future<void> loadStatistics({int? groupId}) async {
    _filterGroupId = groupId;
    notifyListeners();
  }

  @override
  Future<void> loadScoreConfig() async {}

  @override
  Future<void> loadRecords({
    String? targetType,
    int? targetId,
    int? groupId,
    bool resetFilters = false,
  }) async {
    loadCalls.add((
      targetType: targetType,
      targetId: targetId,
      groupId: groupId,
    ));
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

class _FakeStudentProvider extends StudentProvider {
  @override
  List<Student> get students => const [];

  @override
  List<Map<String, dynamic>> get studentsWithGroup => const [];

  @override
  Future<void> loadStudents({int? groupId}) async {}
}

class _FakeScoreItemProvider extends ScoreItemProvider {
  @override
  List<ScoreItem> get items => const [];

  @override
  Future<void> loadItems() async {}
}

class _FakeAuthProvider extends AuthProvider {
  @override
  bool get isUnlocked => false;
}

/// 不带数据库的个性化设置：分栏比例仅在内存中变化。
class _FakePersonalizationProvider extends PersonalizationProvider {
  _FakePersonalizationProvider({double ratio = 0.5}) : _ratio = ratio;

  double _ratio;

  @override
  double get analysisSplitRatio => _ratio;

  @override
  Future<void> setAnalysisSplitRatio(double value) async {
    _ratio = value;
    notifyListeners();
  }
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

List<ChangeNotifierProvider> _providers({
  required ScoreProvider scoreProvider,
  GroupProvider? groupProvider,
  PersonalizationProvider? personalization,
}) => [
  ChangeNotifierProvider<ScoreProvider>.value(value: scoreProvider),
  ChangeNotifierProvider<GroupProvider>.value(
    value: groupProvider ?? _FakeGroupProvider(_groups),
  ),
  ChangeNotifierProvider<StudentProvider>(
    create: (_) => _FakeStudentProvider(),
  ),
  ChangeNotifierProvider<ScoreItemProvider>(
    create: (_) => _FakeScoreItemProvider(),
  ),
  ChangeNotifierProvider<AuthProvider>(create: (_) => _FakeAuthProvider()),
  ChangeNotifierProvider<PersonalizationProvider>(
    create: (_) => personalization ?? _FakePersonalizationProvider(),
  ),
];

/// 只渲染左栏（统计报表）。
Widget _buildView({
  required ScoreProvider scoreProvider,
  GroupProvider? groupProvider,
  void Function(String targetType, int targetId, String name)? onSelectTarget,
  void Function(String targetType, int? targetId, String name)? onOpenAnalysis,
}) {
  return MultiProvider(
    providers: _providers(
      scoreProvider: scoreProvider,
      groupProvider: groupProvider,
    ),
    child: MaterialApp(
      home: Scaffold(
        body: StatisticsView(
          onSelectTarget: onSelectTarget,
          onOpenAnalysis: onOpenAnalysis,
        ),
      ),
    ),
  );
}

/// 渲染整个「查询」页（左右分屏）。
Widget _buildPage({
  required ScoreProvider scoreProvider,
  PersonalizationProvider? personalization,
}) {
  return MultiProvider(
    providers: _providers(
      scoreProvider: scoreProvider,
      personalization: personalization,
    ),
    child: const MaterialApp(home: StatisticsAnalysisPage()),
  );
}

void _useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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

  testWidgets('统计报表：点行联动右栏、行尾图标打开图表分析', (tester) async {
    _useDesktopViewport(tester);
    final selects = <String>[];
    final opens = <String>[];

    await tester.pumpWidget(
      _buildView(
        scoreProvider: _FakeScoreProvider(
          students: _students,
          groups: _groupScores,
        ),
        onSelectTarget: (targetType, targetId, name) =>
            selects.add('$targetType/$targetId/$name'),
        onOpenAnalysis: (targetType, targetId, name) =>
            opens.add('$targetType/$targetId/$name'),
      ),
    );
    await tester.pumpAndSettle();

    // 点整行：联动筛选右栏（不跳页）
    await tester.tap(find.byType(RankingTile).first);
    await tester.pumpAndSettle();
    expect(selects, ['student/11/张三']);
    expect(opens, isEmpty);

    // 点行尾「图表分析」图标：打开该目标的图表分析
    await tester.tap(find.byTooltip('图表分析').first);
    await tester.pumpAndSettle();
    expect(opens, ['student/11/张三']);

    // 小组榜同样支持
    selects.clear();
    opens.clear();
    await tester.tap(find.text('小组'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(RankingTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('图表分析').first);
    await tester.pumpAndSettle();
    expect(selects, ['group/1/第一组']);
    expect(opens, ['group/1/第一组']);

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

  testWidgets('分屏页：不再使用 TabBar，左右两栏同时可见且可调比例', (tester) async {
    _useDesktopViewport(tester);
    final scoreProvider = _FakeScoreProvider(
      students: _students,
      groups: _groupScores,
    );

    await tester.pumpWidget(_buildPage(scoreProvider: scoreProvider));
    await tester.pumpAndSettle();

    // 原 Tab 结构已移除
    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(TabBarView), findsNothing);

    // 两栏同时可见，且分别带栏头
    expect(find.byType(ResizableSplitView), findsOneWidget);
    expect(find.byType(StatisticsView), findsOneWidget);
    expect(find.byType(RecordManagementView), findsOneWidget);
    expect(find.text('统计报表'), findsOneWidget);
    expect(find.text('记录管理'), findsOneWidget);
    expect(find.byKey(ResizableSplitView.dividerKey), findsOneWidget);

    // 左栏榜单从栏顶开始排布（不垂直居中）
    expect(
      tester.getTopLeft(find.byType(StatisticsView)).dy,
      0,
      reason: '统计报表应顶对齐',
    );
    expect(
      tester.getTopLeft(find.byType(PaneHeader).first).dy,
      lessThan(48),
      reason: '栏头应贴近栏顶',
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('分屏页：点左栏学生行 → 右栏按该学生筛选，可一键清除', (tester) async {
    _useDesktopViewport(tester);
    final scoreProvider = _FakeScoreProvider(
      students: _students,
      groups: _groupScores,
    );

    await tester.pumpWidget(_buildPage(scoreProvider: scoreProvider));
    await tester.pumpAndSettle();

    // 初始：右栏加载全部学生记录
    expect(scoreProvider.loadCalls.last.targetId, isNull);

    // 点左栏学生行 → 右栏按该学生重新筛选
    await tester.tap(find.byType(RankingTile).first);
    await tester.pumpAndSettle();

    expect(scoreProvider.loadCalls.last, (
      targetType: 'student',
      targetId: 11,
      groupId: null,
    ));
    expect(find.text('已按「张三」筛选'), findsOneWidget);
    // 左栏该行高亮
    expect(
      tester.widget<RankingTile>(find.byType(RankingTile).first).selected,
      isTrue,
    );

    // 清除联动 → 回到全部记录且取消高亮
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(scoreProvider.loadCalls.last, (
      targetType: 'student',
      targetId: null,
      groupId: null,
    ));
    expect(find.text('已按「张三」筛选'), findsNothing);
    expect(
      tester.widget<RankingTile>(find.byType(RankingTile).first).selected,
      isFalse,
    );

    expect(tester.takeException(), isNull);
  });
}
