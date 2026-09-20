import 'package:class_score/models/group.dart';
import 'package:class_score/pages/analysis/statistics_page.dart';
import 'package:class_score/providers/group_provider.dart';
import 'package:class_score/providers/score_provider.dart';
import 'package:class_score/utils/ranking.dart';
import 'package:class_score/widgets/ranking_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 仅提供内存数据的 Provider，避免测试中访问数据库。

class _FakeScoreProvider extends ScoreProvider {
  _FakeScoreProvider({
    List<Map<String, dynamic>> students = const [],
    List<Map<String, dynamic>> groups = const [],
    bool mergeSameRank = true,
    bool competitionRanking = true,
  }) : _students = students,
       _groups = groups,
       _mergeSameRank = mergeSameRank,
       _competitionRanking = competitionRanking;

  final List<Map<String, dynamic>> _students;
  final List<Map<String, dynamic>> _groups;
  final bool _mergeSameRank;
  final bool _competitionRanking;

  @override
  List<Map<String, dynamic>> get studentTotalScores => _students;

  @override
  List<Map<String, dynamic>> get groupTotalScores => _groups;

  @override
  bool get mergeSameRank => _mergeSameRank;

  @override
  bool get competitionRanking => _competitionRanking;

  @override
  Future<void> loadStatistics({int? groupId}) async {}
}

class _FakeGroupProvider extends GroupProvider {
  @override
  List<Group> get groups => const [];

  @override
  Future<void> loadGroups() async {}
}

/// 100 / 100 / 99 / 99 / 99（总分降序）
const List<Map<String, dynamic>> _tiedStudents = [
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
    'total_score': 100.0,
  },
  {
    'id': 13,
    'name': '王五',
    'student_number': '003',
    'group_name': '乙组',
    'total_score': 99.0,
  },
  {
    'id': 14,
    'name': '赵六',
    'student_number': '004',
    'group_name': '乙组',
    'total_score': 99.0,
  },
  {
    'id': 15,
    'name': '钱七',
    'student_number': '005',
    'group_name': '丙组',
    'total_score': 99.0,
  },
];

const List<Map<String, dynamic>> _tiedGroups = [
  {'id': 1, 'name': '甲组', 'total_score': 30.0, 'member_count': 6},
  {'id': 2, 'name': '乙组', 'total_score': 30.0, 'member_count': 5},
  {'id': 3, 'name': '丙组', 'total_score': 20.0, 'member_count': 4},
];

Widget _buildView({required ScoreProvider scoreProvider}) {
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

List<int> _ranksOf(WidgetTester tester) => tester
    .widgetList<RankingTile>(find.byType(RankingTile))
    .map((t) => t.rank)
    .toList();

/// 第 [index] 个名次组与上一个名次组之间的垂直间距。
double _groupGap(WidgetTester tester, int index) =>
    tester.getTopLeft(find.byType(RankingGroup).at(index)).dy -
    tester.getBottomLeft(find.byType(RankingGroup).at(index - 1)).dy;

/// 第 [index] 个名次组内的行数。
int _rowsInGroup(WidgetTester tester, int index) => find
    .descendant(
      of: find.byType(RankingGroup).at(index),
      matching: find.byType(RankingTile),
    )
    .evaluate()
    .length;

void _useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('名次计算', () {
    test('默认使用标准比赛名次：并列后按实际位置跳号', () {
      final entries = buildRankedEntries(_tiedStudents);

      // 100、100、99、99、99 → 第1、第1、第3、第3、第3名
      expect(entries.map((e) => e.rank).toList(), [1, 3]);
      expect(entries.map((e) => e.count).toList(), [2, 3]);
      expect(entries.first.rows.map((r) => r['name']).toList(), ['张三', '李四']);
      expect(entries.last.rows.map((r) => r['name']).toList(), [
        '王五',
        '赵六',
        '钱七',
      ]);
      // 每人一行展开后，名次序列为 1,1,3,3,3
      expect(entries.expand((e) => e.rows.map((_) => e.rank)).toList(), [
        1,
        1,
        3,
        3,
        3,
      ]);
    });

    test('可切换为紧凑名次：只按不同分数递增', () {
      final entries = buildRankedEntries(
        _tiedStudents,
        competitionRanking: false,
      );

      expect(entries.map((e) => e.rank).toList(), [1, 2]);
      expect(entries.map((e) => e.count).toList(), [2, 3]);
      expect(entries.expand((e) => e.rows.map((_) => e.rank)).toList(), [
        1,
        1,
        2,
        2,
        2,
      ]);
    });

    test('关闭合并后每条数据独立成组，但名次仍然并列', () {
      final entries = buildRankedEntries(_tiedStudents, mergeSameRank: false);

      expect(entries.length, 5);
      expect(entries.every((e) => e.count == 1), isTrue);
      expect(entries.map((e) => e.rank).toList(), [1, 1, 3, 3, 3]);

      final dense = buildRankedEntries(
        _tiedStudents,
        mergeSameRank: false,
        competitionRanking: false,
      );
      expect(dense.map((e) => e.rank).toList(), [1, 1, 2, 2, 2]);
    });

    test('名次以展示分数（1 位小数）判定，并兼容乱序入参', () {
      final entries = buildRankedEntries([
        {'name': 'A', 'total_score': 99.01},
        {'name': 'B', 'total_score': 99.04},
        {'name': 'C', 'total_score': 100.06},
      ]);

      // 100.06 → 100.1（第1名）；99.01 与 99.04 都显示 99.0 → 同为第2名
      expect(entries.map((e) => e.rank).toList(), [1, 2]);
      expect(entries.last.rows.map((r) => r['name']).toList(), ['B', 'A']);
    });

    test('名次徽章：前三名为金 / 银 / 铜，其余沿用学生蓝、小组紫', () {
      const scheme = ColorScheme.light();

      expect(
        RankingMetrics.badgeColor(rank: 1, isGroup: false, scheme: scheme),
        Colors.amber,
      );
      expect(
        RankingMetrics.badgeColor(rank: 2, isGroup: false, scheme: scheme),
        Colors.grey.shade300,
      );
      expect(
        RankingMetrics.badgeColor(rank: 3, isGroup: false, scheme: scheme),
        Colors.orange.shade300,
      );
      expect(
        RankingMetrics.badgeColor(rank: 4, isGroup: false, scheme: scheme),
        Colors.blue.shade100,
      );
      expect(
        RankingMetrics.badgeColor(rank: 4, isGroup: true, scheme: scheme),
        Colors.purple.shade100,
      );
    });

    test('同名次合并与标准比赛名次默认开启', () {
      final provider = ScoreProvider();
      expect(provider.mergeSameRank, isTrue);
      expect(provider.competitionRanking, isTrue);
    });
  });

  group('统计报表排名榜', () {
    testWidgets('学生榜：同名次共处一个名次组，不同名次之间统一留白', (tester) async {
      _useDesktopViewport(tester);
      await tester.pumpWidget(
        _buildView(scoreProvider: _FakeScoreProvider(students: _tiedStudents)),
      );
      await tester.pumpAndSettle();

      // 100/100 → 第1名组（2 人）；99/99/99 → 第3名组（3 人）
      expect(find.byType(RankingGroup), findsNWidgets(2));
      expect(_rowsInGroup(tester, 0), 2);
      expect(_rowsInGroup(tester, 1), 3);
      expect(_ranksOf(tester), [1, 1, 3, 3, 3]);

      // 固定行高：学生行与小组行一致
      for (var i = 0; i < 5; i++) {
        expect(
          tester.getSize(find.byType(RankingTile).at(i)).height,
          RankingMetrics.rowHeight,
        );
      }
      // 不同名次之间的间距统一
      expect(_groupGap(tester, 1), RankingMetrics.rankGroupSpacing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('小组榜：与学生榜同高同间距，副标题为成员数', (tester) async {
      _useDesktopViewport(tester);
      await tester.pumpWidget(
        _buildView(scoreProvider: _FakeScoreProvider(groups: _tiedGroups)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('小组'));
      await tester.pumpAndSettle();

      expect(find.byType(RankingGroup), findsNWidgets(2));
      expect(_rowsInGroup(tester, 0), 2);
      expect(_rowsInGroup(tester, 1), 1);
      expect(_ranksOf(tester), [1, 1, 3]);
      for (var i = 0; i < 3; i++) {
        expect(
          tester.getSize(find.byType(RankingTile).at(i)).height,
          RankingMetrics.rowHeight,
          reason: '小组行应与学生行同高',
        );
      }
      expect(_groupGap(tester, 1), RankingMetrics.rankGroupSpacing);
      // 小组行副标题为成员数（与学生行的小组名同为两行结构）
      expect(find.text('6 名成员'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('关闭同名次合并：名次仍并列，每行独立成组且等距', (tester) async {
      _useDesktopViewport(tester);
      await tester.pumpWidget(
        _buildView(
          scoreProvider: _FakeScoreProvider(
            students: _tiedStudents,
            mergeSameRank: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RankingGroup), findsNWidgets(5));
      for (var i = 0; i < 5; i++) {
        expect(_rowsInGroup(tester, i), 1);
      }
      expect(_ranksOf(tester), [1, 1, 3, 3, 3]);
      for (var i = 1; i < 5; i++) {
        expect(_groupGap(tester, i), RankingMetrics.rowSpacing);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('可切换为紧凑名次：并列后不跳号', (tester) async {
      _useDesktopViewport(tester);
      await tester.pumpWidget(
        _buildView(
          scoreProvider: _FakeScoreProvider(
            students: _tiedStudents,
            competitionRanking: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_ranksOf(tester), [1, 1, 2, 2, 2]);
      expect(tester.takeException(), isNull);
    });
  });
}
