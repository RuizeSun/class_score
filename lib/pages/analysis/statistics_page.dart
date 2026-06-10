import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/score_provider.dart';
import '../../providers/group_provider.dart';
import 'analysis_page.dart';

class StatisticsAnalysisPage extends StatefulWidget {
  const StatisticsAnalysisPage({super.key});

  @override
  State<StatisticsAnalysisPage> createState() => _StatisticsAnalysisPageState();
}

class _StatisticsAnalysisPageState extends State<StatisticsAnalysisPage> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 0,
          bottom: const TabBar(
            tabs: [
              Tab(text: '统计报表'),
              Tab(text: '图表分析'),
            ],
          ),
        ),
        body: const TabBarView(children: [StatisticsView(), AnalysisView()]),
      ),
    );
  }
}

class StatisticsView extends StatefulWidget {
  const StatisticsView({super.key});

  @override
  State<StatisticsView> createState() => _StatisticsViewState();
}

class _StatisticsViewState extends State<StatisticsView> {
  // 切换学生/小组视图
  bool _showGroup = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GroupProvider>().loadGroups();
      context.read<ScoreProvider>().loadStatistics();
    });
  }

  @override
  Widget build(BuildContext context) {
    final studentScores = context.watch<ScoreProvider>().studentTotalScores;
    final groupScores = context.watch<ScoreProvider>().groupTotalScores;
    final groups = context.watch<GroupProvider>().groups;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 学生/小组切换
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('学生'),
                icon: Icon(Icons.person),
              ),
              ButtonSegment(
                value: true,
                label: Text('小组'),
                icon: Icon(Icons.groups),
              ),
            ],
            selected: {_showGroup},
            onSelectionChanged: (v) {
              setState(() => _showGroup = v.first);
            },
            style: const ButtonStyle(iconSize: WidgetStatePropertyAll(18)),
          ),
          const SizedBox(height: 8),
          // 标题
          Text(
            _showGroup ? '小组总分排行' : '学生个人总分',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          // 学生模式下显示按小组筛选
          if (!_showGroup) ...[
            DropdownButtonFormField<int?>(
              initialValue: context.watch<ScoreProvider>().filterGroupId,
              decoration: const InputDecoration(
                labelText: '筛选小组',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('全部小组')),
                ...groups.map(
                  (g) => DropdownMenuItem(value: g.id, child: Text(g.name)),
                ),
              ],
              onChanged: (v) {
                context.read<ScoreProvider>().loadStatistics(groupId: v);
              },
            ),
          ],
          const SizedBox(height: 8),
          // 数据列表
          if (_showGroup)
            // 小组总分列表
            groupScores.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('暂无数据'),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: groupScores.length,
                    itemBuilder: (_, i) {
                      final g = groupScores[i];
                      final score = (g['total_score'] as num).toDouble();
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          backgroundColor: Colors.purple.shade100,
                          child: Text(
                            '${i + 1}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        title: Text(g['name'] as String),
                        trailing: Text(
                          score.toStringAsFixed(1),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: score >= 0 ? Colors.green : Colors.red,
                          ),
                        ),
                      );
                    },
                  )
          else
            // 学生总分列表
            studentScores.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('暂无数据'),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: studentScores.length,
                    itemBuilder: (_, i) {
                      final s = studentScores[i];
                      final score = (s['total_score'] as num).toDouble();
                      final studentNumber =
                          s['student_number'] as String? ?? '';
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          backgroundColor: Colors.blue.shade100,
                          child: Text(
                            '${i + 1}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        title: Text(s['name'] as String),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(s['group_name'] as String? ?? ''),
                            if (studentNumber.isNotEmpty)
                              Text(
                                '学号: $studentNumber',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                          ],
                        ),
                        trailing: Text(
                          score.toStringAsFixed(1),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: score >= 0 ? Colors.green : Colors.red,
                          ),
                        ),
                      );
                    },
                  ),
        ],
      ),
    );
  }
}
