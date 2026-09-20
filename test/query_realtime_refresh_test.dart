import 'package:class_score/models/group.dart';
import 'package:class_score/pages/analysis/statistics_page.dart';
import 'package:class_score/providers/group_provider.dart';
import 'package:class_score/providers/score_provider.dart';
import 'package:class_score/widgets/ranking_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 可变的假 Provider：模拟「评分记录发生变化 → 重新加载统计报表」后的通知。
///
/// 真实的刷新链路由 ScoreProvider._reloadAfterScoreMutation() 完成
/// （loadRecords + loadStatistics），这里只验证左栏榜单会随统计数据的
/// 变化就地重排——即用户不再需要切走再回来才能看到新名次。
class _MutableScoreProvider extends ScoreProvider {
  _MutableScoreProvider({required List<Map<String, dynamic>> students})
    : _students = students;

  List<Map<String, dynamic>> _students;

  @override
  List<Map<String, dynamic>> get studentTotalScores => _students;

  @override
  List<Map<String, dynamic>> get groupTotalScores => const [];

  @override
  Future<void> loadStatistics({int? groupId}) async {}

  /// 模拟一次「评分记录变动 → 统计报表重新加载」。
  void applyStatistics(List<Map<String, dynamic>> students) {
    _students = students;
    notifyListeners();
  }
}

class _FakeGroupProvider extends GroupProvider {
  @override
  List<Group> get groups => const [];

  @override
  Future<void> loadGroups() async {}
}

const List<Map<String, dynamic>> _students = [
  {
    'id': 11,
    'name': '张三',
    'student_number': '001',
    'group_name': '甲组',
    'total_score': 100.0,
  },
  {
    'id': 12,
    'name': '李四',
    'student_number': '002',
    'group_name': '甲组',
    'total_score': 90.0,
  },
  {
    'id': 13,
    'name': '王五',
    'student_number': '003',
    'group_name': '乙组',
    'total_score': 80.0,
  },
];

Widget _buildView(ScoreProvider scoreProvider) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<ScoreProvider>.value(value: scoreProvider),
      ChangeNotifierProvider<GroupProvider>(
        create: (_) => _FakeGroupProvider(),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: StatisticsView())),
  );
}

void _useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 榜单中对象的显示顺序（按行取标题）。
List<String> _namesOf(WidgetTester tester) => tester
    .widgetList<RankingTile>(find.byType(RankingTile))
    .map((t) => t.title)
    .toList();

void main() {
  testWidgets('评分记录变动后，查询页左栏榜单就地刷新（无需重新进入页面）', (tester) async {
    _useDesktopViewport(tester);
    final provider = _MutableScoreProvider(students: _students);

    await tester.pumpWidget(_buildView(provider));
    await tester.pumpAndSettle();

    expect(_namesOf(tester), ['张三', '李四', '王五']);
    expect(find.text('100.0'), findsOneWidget);
    expect(find.text('80.0'), findsOneWidget);

    // 评分后：王五 80 → 110，反超张三升到第 1，分数文本同步刷新
    provider.applyStatistics([
      _students[0],
      _students[1],
      {..._students[2], 'total_score': 110.0},
    ]);
    await tester.pumpAndSettle();

    expect(_namesOf(tester), ['王五', '张三', '李四']);
    expect(find.text('110.0'), findsOneWidget);
    expect(find.text('80.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
