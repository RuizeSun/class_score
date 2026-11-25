import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/score_provider.dart';
import '../../providers/group_provider.dart';
import '../../utils/ranking.dart';
import '../../widgets/glass_buttons.dart';
import '../../widgets/glass_controls.dart';
import '../../widgets/pane_header.dart';
import '../../widgets/ranking_tile.dart';
import '../../widgets/resizable_split_view.dart';

/// 「高级查询」页：左侧查询条件、右侧查询结果的平板式分屏。
///
/// 之前的版本把所有内容竖着堆在一栏里：改一次条件要往下滚才能看到结果，
/// 结果多时又要把条件滚回去。改成分屏后条件常驻左栏、结果独占右栏，
/// 中间竖线可拖拽调比例（双击复位），与学生/小组榜一致的
/// [RankingTile] 行样式也顺带统一了两处的观感。
class RankingSummaryPage extends StatefulWidget {
  const RankingSummaryPage({super.key});

  @override
  State<RankingSummaryPage> createState() => _RankingSummaryPageState();
}

class _RankingSummaryPageState extends State<RankingSummaryPage> {
  // 目标类型切换：学生/小组
  bool _showGroup = false;

  // 学生模式的小组筛选
  int? _filterGroupId;

  /// 左右栏比例（左栏占比）。
  ///
  /// 只做本页的局部状态，不写库：高级查询是一次性查看页，条件栏比榜单窄
  /// 得多，固定给个偏窄的初始比例即可；用户拖动只影响这次打开。
  double _splitRatio = 0.34;

  @override
  void initState() {
    super.initState();
    // 结果可能来自上一次打开本页时留下的查询（Provider 在应用级常驻）。
    // 这时「学生/小组」的本地开关必须跟着结果走，否则右栏标题与列表内容对不上。
    final provider = context.read<ScoreProvider>();
    _showGroup = provider.advancedShowGroup;
    _filterGroupId = provider.advancedGroupId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GroupProvider>().loadGroups();
    });
  }

  /// 获取所有可用的周期选项
  List<int> _getAvailablePeriods() {
    final currentPeriod = context.read<ScoreProvider>().currentPeriod;
    return List.generate(currentPeriod, (i) => i + 1);
  }

  /// 格式化时间显示
  String _formatTime(String? isoTime) {
    if (isoTime == null || isoTime.isEmpty) return '暂无数据';
    try {
      final dt = DateTime.parse(isoTime);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return isoTime.substring(0, 16).replaceFirst('T', ' ');
    }
  }

  /// 周期已选全时执行一次查询（改条件即查，不用再点按钮）。
  Future<void> _runIfReady(ScoreProvider provider) async {
    final start = provider.advancedStartPeriod;
    final end = provider.advancedEndPeriod;
    if (start == null || end == null) return;
    provider.setAdvancedShowGroup(_showGroup);
    await provider.executeAdvancedQuery();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('高级查询'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
      ),
      body: ResizableSplitView(
        ratio: _splitRatio,
        minLeftWidth: 300,
        minRightWidth: 320,
        onRatioChanged: (value) => setState(() => _splitRatio = value),
        left: _buildQueryPane(),
        right: _buildResultPane(),
      ),
    );
  }

  // ==================== 左栏：查询条件 ====================

  Widget _buildQueryPane() {
    final scoreProvider = context.watch<ScoreProvider>();
    final groups = context.watch<GroupProvider>().groups;

    final periods = _getAvailablePeriods();
    final startPeriod = scoreProvider.advancedStartPeriod;
    final endPeriod = scoreProvider.advancedEndPeriod;
    final results = scoreProvider.advancedResults;
    final timeRange = scoreProvider.advancedTimeRange;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PaneHeader(
            icon: Icons.filter_list,
            title: '查询条件',
            padding: EdgeInsets.fromLTRB(0, 4, 0, 8),
          ),

          // 查询类型
          const _SectionLabel('查询类型'),
          const SizedBox(height: 6),
          GlassSegmentedChoice<bool>(
            selected: _showGroup,
            expand: true,
            onChanged: (value) {
              setState(() {
                _showGroup = value;
                _filterGroupId = null;
                scoreProvider.setAdvancedGroupId(null);
              });
              _runIfReady(scoreProvider);
            },
            options: const [
              GlassSegmentedOption(
                value: false,
                label: '个人',
                icon: Icons.person,
              ),
              GlassSegmentedOption(value: true, label: '小组', icon: Icons.groups),
            ],
          ),
          const SizedBox(height: 16),

          // 学生模式：按小组筛选
          if (!_showGroup) ...[
            const _SectionLabel('筛选小组'),
            const SizedBox(height: 6),
            GlassDropdownField<int?>(
              initialValue: _filterGroupId,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: [
                const DropdownMenuItem(value: null, child: Text('全部小组')),
                ...groups.map(
                  (g) => DropdownMenuItem(value: g.id, child: Text(g.name)),
                ),
              ],
              onChanged: (v) {
                setState(() => _filterGroupId = v);
                scoreProvider.setAdvancedGroupId(v);
                _runIfReady(scoreProvider);
              },
            ),
            const SizedBox(height: 16),
          ],

          // 小组模式：是否把「不参与小组量化评分」的学生也算进总分
          if (_showGroup) ...[
            const _SectionLabel('统计口径'),
            const SizedBox(height: 2),
            GlassSwitchTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: scoreProvider.advancedCountExcludedStudents,
              title: const Text(
                '计入未参与小组量化评分的学生',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                '关闭时只累计参与小组量化评分的成员；打开后这类学生也按普通成员计入小组总分与人均分母',
                style: TextStyle(fontSize: 11),
              ),
              onChanged: (v) {
                scoreProvider.setAdvancedCountExcludedStudents(v);
                _runIfReady(scoreProvider);
              },
            ),
            const SizedBox(height: 16),
          ],

          // 周期范围
          const _SectionLabel('周期范围'),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: GlassDropdownField<int?>(
                  initialValue: startPeriod,
                  isExpanded: true,
                  height: 38,
                  menuWidth: 160,
                  decoration: const InputDecoration(
                    hintText: '起始周期',
                    isDense: true,
                  ),
                  items: periods
                      .map(
                        (p) => DropdownMenuItem(
                          value: p,
                          child: Text('第 $p 期'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    scoreProvider.setAdvancedPeriodRange(v, endPeriod);
                    if (v != null && (endPeriod == null || endPeriod < v)) {
                      scoreProvider.setAdvancedPeriodRange(v, v);
                    }
                    _runIfReady(scoreProvider);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GlassDropdownField<int?>(
                  initialValue: endPeriod,
                  isExpanded: true,
                  height: 38,
                  menuWidth: 160,
                  decoration: const InputDecoration(
                    hintText: '结束周期',
                    isDense: true,
                  ),
                  items: periods
                      .map(
                        (p) => DropdownMenuItem(
                          value: p,
                          child: Text('第 $p 期'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    final currentStart = scoreProvider.advancedStartPeriod;
                    if (v != null && (currentStart == null || v < currentStart)) {
                      scoreProvider.setAdvancedPeriodRange(v, v);
                    } else {
                      scoreProvider.setAdvancedPeriodRange(currentStart, v);
                    }
                    _runIfReady(scoreProvider);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 时间范围预览
          if (startPeriod != null && endPeriod != null)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.calendar_today, size: 14),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '第 $startPeriod 期 至 第 $endPeriod 期',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        Icons.arrow_upward,
                        size: 12,
                        color: Colors.green,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '首次评分：${timeRange != null ? _formatTime(timeRange['first_score']) : '计算中...'}',
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Icon(
                        Icons.arrow_downward,
                        size: 12,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '末次评分：${timeRange != null ? _formatTime(timeRange['last_score']) : '计算中...'}',
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),

          Align(
            alignment: Alignment.centerLeft,
            child: GlassActionButton.icon(
              onPressed: results.isEmpty && startPeriod == null
                  ? null
                  : () async {
                      scoreProvider.clearAdvancedQuery();
                      setState(() => _filterGroupId = null);
                    },
              icon: const Icon(Icons.clear_all, size: 18),
              label: const Text('清除条件'),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 右栏：查询结果 ====================

  Widget _buildResultPane() {
    final scoreProvider = context.watch<ScoreProvider>();
    final results = scoreProvider.advancedResults;
    final startPeriod = scoreProvider.advancedStartPeriod;
    final endPeriod = scoreProvider.advancedEndPeriod;
    final ready = startPeriod != null && endPeriod != null;

    final rankedEntries = buildRankedEntries(
      results,
      mergeSameRank: scoreProvider.mergeSameRank,
      competitionRanking: scoreProvider.competitionRanking,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: Icons.leaderboard_outlined,
          title: '查询结果',
          actions: [
            if (results.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '共 ${results.length} 条',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
        Expanded(
          child: !ready
              ? const _ResultHint(
                  icon: Icons.event_note_outlined,
                  title: '请选择周期范围',
                  hint: '左侧选择起始与结束周期后自动查询',
                )
              : rankedEntries.isEmpty
              ? const _ResultHint(
                  icon: Icons.search_off,
                  title: '暂无数据',
                  hint: '该周期范围内没有评分记录',
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: RankingMetrics.contentMaxWidth,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          RankingListHeader(title: _showGroup ? '小组' : '学生'),
                          for (var i = 0; i < rankedEntries.length; i++) ...[
                            if (i > 0)
                              SizedBox(
                                height: scoreProvider.mergeSameRank
                                    ? RankingMetrics.rankGroupSpacing
                                    : RankingMetrics.rowSpacing,
                              ),
                            RankingGroup(
                              children: [
                                for (final row in rankedEntries[i].rows)
                                  _buildResultTile(rankedEntries[i].rank, row),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// 结果行：与「统计报表」左右栏共用 [RankingTile]，行高/名次徽章/分数列一致。
  Widget _buildResultTile(int rank, Map<String, dynamic> data) {
    final isGroup = _showGroup;
    final score = (data['total_score'] as num?)?.toDouble() ?? 0.0;
    final scheme = Theme.of(context).colorScheme;
    final name = (data['name'] as String?) ?? '';
    final memberCount = (data['member_count'] as num?)?.toInt() ?? 0;

    return RankingTile(
      rank: rank,
      score: score,
      title: name,
      studentNumber: isGroup ? '' : (data['student_number'] as String? ?? ''),
      subtitle: isGroup ? '$memberCount 名成员' : (data['group_name'] as String? ?? ''),
      subtitleIcon: isGroup ? Icons.person_outline : Icons.groups_outlined,
      badgeColor: RankingMetrics.badgeColor(
        rank: rank,
        isGroup: isGroup,
        scheme: scheme,
      ),
    );
  }
}

/// 条件栏的小节标题。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.bold,
        color: Colors.black87,
      ),
    );
  }
}

/// 右栏的空/未就绪提示。
class _ResultHint extends StatelessWidget {
  const _ResultHint({
    required this.icon,
    required this.title,
    required this.hint,
  });

  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Colors.grey.shade400),
            const SizedBox(height: 10),
            Text(
              title,
              style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 4),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }
}
