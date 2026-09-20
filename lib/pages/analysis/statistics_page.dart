import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/score_item.dart';
import '../../providers/score_provider.dart';
import '../../providers/score_item_provider.dart';
import '../../providers/group_provider.dart';
import '../../providers/student_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/personalization_provider.dart';
import '../../utils/ranking.dart';
import '../../widgets/motion.dart';
import '../../widgets/pane_header.dart';
import '../../widgets/ranking_tile.dart';
import '../../widgets/resizable_split_view.dart';
import '../../widgets/score_record_tile.dart';
import '../../widgets/student_name_text.dart';
import 'analysis_detail_page.dart';
import 'ranking_summary_page.dart';

/// 「查询」页：左侧「统计报表」+ 右侧「记录管理」的平板式分屏。
///
/// 两栏同时可见，中间一条竖线可拖拽调整比例（比例持久化到个性化设置）；
/// 点击左栏榜单行即联动筛选右栏该学生/小组的记录，避免数据与
/// 小组/学生名字被分在两个互斥 Tab 里、互相看不到。
class StatisticsAnalysisPage extends StatefulWidget {
  const StatisticsAnalysisPage({super.key});

  @override
  State<StatisticsAnalysisPage> createState() => _StatisticsAnalysisPageState();
}

class _StatisticsAnalysisPageState extends State<StatisticsAnalysisPage> {
  /// 左栏选中的目标：联动右栏记录列表，并高亮左栏该行。
  ({String type, int id, String name})? _selectedTarget;

  /// 打开图表分析页：targetId 为空时打开班级（全部）视图。
  void _openAnalysis(String targetType, int? targetId, String name) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnalysisDetailPage(
          targetType: targetType,
          targetId: targetId,
          title: targetId == null ? '班级图表分析' : '图表分析 · $name',
        ),
      ),
    );
  }

  /// 左栏点击学生/小组：右栏筛选该目标的记录（两栏联动）。
  void _selectTarget(String targetType, int targetId, String name) {
    setState(
      () => _selectedTarget = (type: targetType, id: targetId, name: name),
    );
  }

  void _clearSelection() {
    setState(() => _selectedTarget = null);
  }

  @override
  Widget build(BuildContext context) {
    final ratio = context.watch<PersonalizationProvider>().analysisSplitRatio;
    final selected = _selectedTarget;

    return Scaffold(
      body: ResizableSplitView(
        ratio: ratio,
        onRatioChanged: (value) => context
            .read<PersonalizationProvider>()
            .setAnalysisSplitRatio(value),
        left: StatisticsView(
          onSelectTarget: _selectTarget,
          onOpenAnalysis: _openAnalysis,
          selectedTarget: selected == null
              ? null
              : (type: selected.type, id: selected.id),
        ),
        right: RecordManagementView(
          externalFilter: selected,
          onClearExternalFilter: _clearSelection,
        ),
      ),
    );
  }
}

// ==================== 统计报表 ====================

/// 统计报表栏：学生榜 / 小组榜（分屏左栏）。
class StatisticsView extends StatefulWidget {
  /// 点击学生/小组行：联动筛选右侧记录列表（[targetId] 必不为空）。
  final void Function(String targetType, int targetId, String name)?
  onSelectTarget;

  /// 点击行尾「图表分析」图标：打开对应目标的图表分析页。
  /// [targetType] = 'student' | 'group'，[targetId] 为空表示班级（全部）视图。
  final void Function(String targetType, int? targetId, String name)?
  onOpenAnalysis;

  /// 当前选中的目标：用于高亮该行（与右栏筛选保持一致）。
  final ({String type, int id})? selectedTarget;

  const StatisticsView({
    super.key,
    this.onSelectTarget,
    this.onOpenAnalysis,
    this.selectedTarget,
  });

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
    final scoreProvider = context.watch<ScoreProvider>();
    final studentScores = scoreProvider.studentTotalScores;
    final groupScores = scoreProvider.groupTotalScores;
    final groups = context.watch<GroupProvider>().groups;
    // 仅「全部小组」时提供班级图表分析入口（小组模式等效全部小组）
    final showClassAnalysis = _showGroup || scoreProvider.filterGroupId == null;
    // 名次分组：默认合并同名次并使用标准比赛名次（并列后跳号），
    // 可在「计分规则 → 统计报表」调整；学生榜与小组榜共用同一套名次计算与行样式。
    final rankedEntries = buildRankedEntries(
      _showGroup ? groupScores : studentScores,
      mergeSameRank: scoreProvider.mergeSameRank,
      competitionRanking: scoreProvider.competitionRanking,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: Alignment.topCenter,
        // 榜单与学生/小组切换同宽居中：宽屏下不把姓名与分数拉开
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: RankingMetrics.contentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 栏头：替代原 Tab，标明本栏内容
              const PaneHeader(
                icon: Icons.leaderboard_outlined,
                title: '统计报表',
                padding: EdgeInsets.fromLTRB(0, 0, 0, 8),
              ),
              // 工具栏：学生/小组切换 + 小组筛选 + 查询入口收拢在同一行
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
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
                    style: const ButtonStyle(
                      iconSize: WidgetStatePropertyAll(18),
                    ),
                  ),
                  // 学生模式下可按小组筛选榜单
                  if (!_showGroup)
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<int?>(
                        initialValue: scoreProvider.filterGroupId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          prefixIcon: Icon(Icons.filter_alt_outlined, size: 18),
                          prefixIconConstraints: BoxConstraints(minWidth: 36),
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('全部小组'),
                          ),
                          ...groups.map(
                            (g) => DropdownMenuItem(
                              value: g.id,
                              child: Text(g.name),
                            ),
                          ),
                        ],
                        onChanged: (v) {
                          context.read<ScoreProvider>().loadStatistics(
                            groupId: v,
                          );
                        },
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (ctx) => const RankingSummaryPage(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.filter_list, size: 18),
                    label: const Text('高级查询'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                    ),
                  ),
                  if (showClassAnalysis)
                    FilledButton.tonalIcon(
                      onPressed: () => widget.onOpenAnalysis?.call(
                        _showGroup ? 'group' : 'student',
                        null,
                        '班级',
                      ),
                      icon: const Icon(Icons.bar_chart, size: 18),
                      label: const Text('班级图表分析'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              // 榜单：同名次共处一个圆角块（RankingGroup），不同名次之间统一留白。
              // 学生 / 小组切换时整块淡入上移；两块高度不同，由 AnimatedSize
              // 平滑高度变化，避免切换瞬间下方内容整体跳位。
              AppSizeTransition(
                child: FadeThroughSwitcher(
                  switchKey: _showGroup ? 'group' : 'student',
                  child: rankedEntries.isEmpty
                      ? const RankingEmptyState()
                      : Column(
                          children: [
                            // 表头：与行内「名称 / 总分」两列对齐
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
                                    _buildRankingTile(
                                      rankedEntries[i].rank,
                                      row,
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建一行排名行：学生榜为「姓名#学号 + 所属小组」，小组榜为「组名 + 成员数」，
  /// 两者结构与行高一致（见 [RankingTile]）。
  /// 点击整行 = 联动筛选右栏记录；行尾图标 = 打开该目标的图表分析。
  Widget _buildRankingTile(int rank, Map<String, dynamic> data) {
    final isGroup = _showGroup;
    final targetType = isGroup ? 'group' : 'student';
    final name = data['name'] as String;
    final id = data['id'] as int;
    final scheme = Theme.of(context).colorScheme;

    return RankingTile(
      rank: rank,
      score: (data['total_score'] as num).toDouble(),
      title: name,
      studentNumber: isGroup ? '' : (data['student_number'] as String? ?? ''),
      subtitle: isGroup
          ? '${(data['member_count'] as num?)?.toInt() ?? 0} 名成员'
          : (data['group_name'] as String? ?? ''),
      subtitleIcon: isGroup ? Icons.person_outline : Icons.groups_outlined,
      badgeColor: RankingMetrics.badgeColor(
        rank: rank,
        isGroup: isGroup,
        scheme: scheme,
      ),
      selected: widget.selectedTarget == (type: targetType, id: id),
      onTap: () => widget.onSelectTarget?.call(targetType, id, name),
      onOpenAnalysis: () => widget.onOpenAnalysis?.call(targetType, id, name),
    );
  }
}

// ==================== 记录管理 ====================

/// 记录管理栏：筛选 + 记录列表（分屏右栏）。
///
/// 支持左栏（统计报表）联动：外部传入 [externalFilter] 时同步筛选并高亮提示。
class RecordManagementView extends StatefulWidget {
  const RecordManagementView({
    super.key,
    this.externalFilter,
    this.onClearExternalFilter,
  });

  /// 左栏联动过来的筛选目标；为空表示无联动筛选。
  final ({String type, int id, String name})? externalFilter;

  /// 清除联动筛选：同时清空本栏筛选与左栏高亮。
  final VoidCallback? onClearExternalFilter;

  @override
  State<RecordManagementView> createState() => _RecordManagementViewState();
}

class _RecordManagementViewState extends State<RecordManagementView> {
  int? _filterGroupId;
  int? _filterStudentId;

  // 批量操作状态
  bool _batchMode = false;
  final Set<int> _selectedRecordIds = {};

  @override
  void initState() {
    super.initState();
    // 左栏可能已选中某个学生/小组（分屏初建时）
    _syncExternalFilter(widget.externalFilter);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GroupProvider>().loadGroups();
      context.read<StudentProvider>().loadStudents();
      context.read<ScoreItemProvider>().loadItems();
      context.read<ScoreProvider>().loadScoreConfig();
      _loadRecords();
    });
  }

  @override
  void didUpdateWidget(covariant RecordManagementView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.externalFilter == widget.externalFilter) return;
    // 左栏选中变化（或清除联动）：同步筛选并重新拉取记录
    _syncExternalFilter(widget.externalFilter);
    _loadRecords();
  }

  /// 把左栏联动的目标同步到本栏筛选状态。
  ///
  /// 学生 → 只筛该学生（小组筛选清空，保证学生下拉仍可选）；
  /// 小组 → 只筛该小组；为空 → 两栏筛选都清空（回到全部记录）。
  void _syncExternalFilter(({String type, int id, String name})? filter) {
    if (filter == null) {
      _filterGroupId = null;
      _filterStudentId = null;
    } else if (filter.type == 'group') {
      _filterGroupId = filter.id;
      _filterStudentId = null;
    } else {
      _filterGroupId = null;
      _filterStudentId = filter.id;
    }
  }

  void _loadRecords() {
    final scoreProvider = context.read<ScoreProvider>();
    if (_filterGroupId != null) {
      if (_filterStudentId != null) {
        scoreProvider.loadRecords(
          targetType: 'student',
          targetId: _filterStudentId,
        );
      } else {
        scoreProvider.loadRecords(groupId: _filterGroupId);
      }
    } else {
      if (_filterStudentId != null) {
        scoreProvider.loadRecords(
          targetType: 'student',
          targetId: _filterStudentId,
        );
      } else {
        scoreProvider.loadRecords(targetType: 'student');
      }
    }
  }

  // ===== 补充/修改变动原因与批量操作逻辑 =====
  /// 补充/修改变动原因：单选或批量。可关联预设评分项或自定义说明。
  /// [targets] 为待处理的记录 map 列表（来自 recordsWithName）。
  Future<void> _runSupplementFlow(List<Map<String, dynamic>> targets) async {
    if (targets.isEmpty || !mounted) return;
    final result = await _showSupplementFormDialog(targets);
    if (result == null || !mounted) return;

    final ids = targets.map((r) => r['id'] as int).toList();
    final reason = result.reason.trim();
    final provider = context.read<ScoreProvider>();

    try {
      if (result.scoreItemId != null && result.item != null) {
        // 关联预设评分项
        final presetScore = result.item!.defaultScore;
        final conflicting = targets.where((r) {
          final orig = (r['score'] as num).toDouble();
          return orig != presetScore;
        }).toList();

        bool applyPreset = false;
        if (conflicting.isNotEmpty) {
          final decision = await _showScoreConflictDialog(
            item: result.item!,
            conflicting: conflicting,
          );
          if (decision == null || !mounted) return; // 用户取消
          applyPreset = decision;
        }

        await provider.batchUpdateRecordComplements(
          ids: ids,
          reason: reason,
          scoreItemId: result.scoreItemId,
          presetScore: presetScore,
          applyPresetScore: applyPreset,
        );
      } else {
        // 自定义：仅写自定义名称与原因，不改变分值
        await provider.batchUpdateRecordComplements(
          ids: ids,
          reason: reason,
          customName: result.customName.trim(),
        );
      }

      _selectedRecordIds.removeAll(ids);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已为 ${ids.length} 条记录保存变动原因'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
    }
  }

  /// 弹出补充/修改变动原因表单。返回 null 表示取消。
  Future<_SupplementResult?> _showSupplementFormDialog(
    List<Map<String, dynamic>> targets,
  ) async {
    final items = context.read<ScoreItemProvider>().items;
    final isBatch = targets.length > 1;
    // 单选时预填已有原因
    final initialReason = !isBatch
        ? (targets.first['reason'] as String? ?? '')
        : '';

    final reasonController = TextEditingController(text: initialReason);
    final customNameController = TextEditingController();
    int? chosenItemId; // null => 自定义

    final result = await showDialog<_SupplementResult>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isCustom = chosenItemId == null;
          return AlertDialog(
            title: Text(isBatch ? '批量补充变动原因' : '补充变动原因'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isBatch
                        ? '为选中的 ${targets.length} 条记录补充原因，可关联预设评分项或自定义说明。'
                        : '为该条记录补充原因，可关联预设评分项或自定义说明。',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 12),
                  // 预设评分项 / 自定义 选择
                  DropdownButtonFormField<int?>(
                    key: ValueKey('item_$chosenItemId'),
                    initialValue: chosenItemId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '预设评分项',
                      border: OutlineInputBorder(),
                      hintText: '选择预设（自定义则不填）',
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('自定义'),
                        ),
                      ),
                      ...items.map(
                        (item) => DropdownMenuItem<int?>(
                          value: item.id,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  item.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _scoreChip(item.defaultScore),
                            ],
                          ),
                        ),
                      ),
                    ],
                    onChanged: (v) => setDialogState(() => chosenItemId = v),
                  ),
                  if (isCustom) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: customNameController,
                      decoration: const InputDecoration(
                        labelText: '评分项名称（自定义）',
                        border: OutlineInputBorder(),
                        hintText: '如：考勤扣分、作业加分',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: reasonController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '变动原因',
                      border: OutlineInputBorder(),
                      hintText: '请输入具体变动原因（可选）',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(
                  ctx,
                  _SupplementResult(
                    scoreItemId: chosenItemId,
                    item: chosenItemId == null
                        ? null
                        : items.firstWhere((i) => i.id == chosenItemId),
                    customName: customNameController.text,
                    reason: reasonController.text,
                  ),
                ),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );

    reasonController.dispose();
    customNameController.dispose();
    return result;
  }

  /// 分值冲突确认弹窗。返回 true=应用预设分值；false=保留原分值；null=取消。
  Future<bool?> _showScoreConflictDialog({
    required ScoreItem item,
    required List<Map<String, dynamic>> conflicting,
  }) async {
    final preset = item.defaultScore;
    final presetLabel = _scoreLabel(preset);
    final isMultiple = conflicting.length > 1;

    String content;
    if (isMultiple) {
      content =
          '所选评分项「${item.name}」的预设分值为 $presetLabel，'
          '与选中的 ${conflicting.length} 条记录当前分值不一致。\n\n'
          '请选择保留各记录当前分值，还是统一改为该评分项的预设分值 $presetLabel。';
    } else {
      final orig = (conflicting.first['score'] as num).toDouble();
      content =
          '所选评分项「${item.name}」的预设分值为 $presetLabel，'
          '与该条记录当前分值 ${_scoreLabel(orig)} 不一致。\n\n'
          '请选择保留记录当前分值，还是改为该评分项的预设分值。';
    }

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('分值不一致'),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('保留原分值'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('应用预设分值'),
          ),
        ],
      ),
    );
  }

  /// 打开回收站（先清理超过 7 天的记录，再展示剩余被删记录）。
  Future<void> _openRecycleBin() async {
    final provider = context.read<ScoreProvider>();
    await provider.purgeExpiredArchives();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => const RecycleBinDialog(),
    );
  }

  String _scoreLabel(double v) {
    if (v > 0) return '+${v.toStringAsFixed(1)}';
    if (v < 0) return v.toStringAsFixed(1);
    return '0.0';
  }

  Widget _scoreChip(double score) {
    final Color color;
    if (score > 0) {
      color = Colors.green.shade700;
    } else if (score < 0) {
      color = Colors.red.shade700;
    } else {
      color = Colors.grey.shade600;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _scoreLabel(score),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }

  void _enterBatchMode() {
    setState(() {
      _batchMode = true;
      _selectedRecordIds.clear();
    });
  }

  void _exitBatchMode() {
    setState(() {
      _batchMode = false;
      _selectedRecordIds.clear();
    });
  }

  void _toggleRecordSelection(int id) {
    setState(() {
      if (!_selectedRecordIds.add(id)) {
        _selectedRecordIds.remove(id);
      }
    });
  }

  void _toggleSelectAll(List<Map<String, dynamic>> records) {
    final allIds = records.map((r) => r['id'] as int).toSet();
    if (allIds.isEmpty) return;
    final allSelected = allIds.every(_selectedRecordIds.contains);
    setState(() {
      if (allSelected) {
        _selectedRecordIds.removeAll(allIds);
      } else {
        _selectedRecordIds.addAll(allIds);
      }
    });
  }

  bool _allSelected(List<Map<String, dynamic>> records) {
    final allIds = records.map((r) => r['id'] as int).toSet();
    return allIds.isNotEmpty && allIds.every(_selectedRecordIds.contains);
  }

  List<Map<String, dynamic>> _selectedRecords(
    List<Map<String, dynamic>> records,
  ) => records.where((r) => _selectedRecordIds.contains(r['id'])).toList();

  /// 批量操作控制栏：非批量时显示「批量操作」入口，批量时显示选择信息与操作按钮
  Widget _buildBatchBar(List<Map<String, dynamic>> records) {
    if (!_batchMode) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: _openRecycleBin,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('回收站'),
            ),
            if (records.isNotEmpty)
              TextButton.icon(
                onPressed: _enterBatchMode,
                icon: const Icon(Icons.checklist, size: 18),
                label: const Text('批量操作'),
              ),
          ],
        ),
      );
    }
    final selected = _selectedRecords(records);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '已选 ${selected.length} 条',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.blueGrey.shade700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => _toggleSelectAll(records),
            child: Text(_allSelected(records) ? '取消全选' : '全选'),
          ),
          TextButton(
            onPressed: selected.isNotEmpty
                ? () => _runSupplementFlow(selected)
                : null,
            child: const Text('补充原因'),
          ),
          TextButton(
            onPressed: selected.isNotEmpty
                ? () => RecordActions.deleteRecords(
                    context,
                    selected,
                    onDeleted: (ids) =>
                        setState(() => _selectedRecordIds.removeAll(ids)),
                  )
                : null,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
          IconButton(
            tooltip: '完成',
            icon: const Icon(Icons.close),
            onPressed: _exitBatchMode,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scoreProvider = context.watch<ScoreProvider>();
    final records = scoreProvider.recordsWithName;
    final allStudents = context.watch<StudentProvider>().students;
    final groups = context.watch<GroupProvider>().groups;
    final isUnlocked = context.watch<AuthProvider>().isUnlocked;

    // 根据所选小组过滤学生列表
    final students = _filterGroupId != null
        ? allStudents.where((s) => s.groupId == _filterGroupId).toList()
        : allStudents;

    return Column(
      children: [
        // 栏头：替代原 Tab，标明本栏内容
        const PaneHeader(icon: Icons.receipt_long_outlined, title: '记录管理'),
        // 左栏联动筛选提示（可一键清除）：出现 / 消失时高度平滑展开收起，
        // 切换筛选对象时提示文字淡入，避免工具栏整体跳动
        AppSizeTransition(
          alignment: Alignment.topLeft,
          child: FadeThroughSwitcher(
            switchKey: widget.externalFilter == null
                ? null
                : '${widget.externalFilter!.type}/${widget.externalFilter!.id}',
            alignment: Alignment.topLeft,
            duration: AppMotion.fast,
            child: widget.externalFilter == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: InputChip(
                        avatar: Icon(
                          widget.externalFilter!.type == 'group'
                              ? Icons.groups
                              : Icons.person,
                          size: 16,
                        ),
                        label: Text('已按「${widget.externalFilter!.name}」筛选'),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: widget.onClearExternalFilter,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
          ),
        ),
        // 筛选区域（定宽 + Wrap：窄栏自动换行，不挤压文字）
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<int?>(
                  key: ValueKey('group_$_filterGroupId'),
                  initialValue: _filterGroupId,
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
                    // 联动筛选的小组可能还没出现在列表中（小组数据仍在加载）
                    if (_filterGroupId != null &&
                        !groups.any((g) => g.id == _filterGroupId))
                      DropdownMenuItem(
                        value: _filterGroupId,
                        child: Text(widget.externalFilter?.name ?? '当前筛选小组'),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _filterGroupId = v;
                      _filterStudentId = null;
                    });
                    _loadRecords();
                  },
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<int?>(
                  key: ValueKey('student_$_filterStudentId'),
                  initialValue: _filterStudentId,
                  decoration: const InputDecoration(
                    labelText: '筛选学生',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部学生')),
                    ...students.map(
                      (s) => DropdownMenuItem(
                        value: s.id,
                        // 姓名#学号（学号灰色）
                        child: StudentNameText(
                          name: s.name,
                          studentNumber: s.studentNumber,
                        ),
                      ),
                    ),
                    // 联动筛选的学生可能还没出现在列表中（学生数据仍在加载），
                    // 补一个匹配项，避免下拉的选中值与 items 不一致
                    if (_filterStudentId != null &&
                        !students.any((s) => s.id == _filterStudentId))
                      DropdownMenuItem(
                        value: _filterStudentId,
                        child: Text(widget.externalFilter?.name ?? '当前筛选学生'),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() => _filterStudentId = v);
                    _loadRecords();
                  },
                ),
              ),
            ],
          ),
        ),
        // 批量操作/回收站控制栏：普通 ↔ 批量模式切换时淡入上移
        if (isUnlocked)
          AppSizeTransition(
            child: FadeThroughSwitcher(
              switchKey: _batchMode,
              duration: AppMotion.fast,
              child: _buildBatchBar(records),
            ),
          ),

        // 记录列表：筛选（含左栏联动）变化时整块淡出 → 淡入。列表批量替换用
        // 更快节奏，避免长列表出现明显的空窗
        Expanded(
          child: FadeThroughSwitcher(
            expand: true,
            duration: AppMotion.fast,
            switchKey: '${_filterGroupId}_$_filterStudentId',
            child: records.isEmpty
                ? const Center(child: Text('暂无评分记录'))
                : ListView.builder(
                    itemCount: records.length,
                    itemBuilder: (_, i) {
                      final r = records[i];
                      final recordId = r['id'] as int;
                      final isSelected = _selectedRecordIds.contains(recordId);

                      // 条目样式与操作逻辑复用「记录管理」的 ScoreRecordTile
                      return ScoreRecordTile(
                        record: r,
                        batchMode: _batchMode,
                        selected: isSelected,
                        onToggleSelect: () => _toggleRecordSelection(recordId),
                        isUnlocked: isUnlocked,
                        onMutated: () =>
                            setState(() => _selectedRecordIds.remove(recordId)),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// 补充/修改变动原因表单的返回结果
class _SupplementResult {
  final int? scoreItemId; // null 表示自定义
  final ScoreItem? item; // 选中的预设评分项（自定义时为 null）
  final String customName;
  final String reason;

  _SupplementResult({
    this.scoreItemId,
    this.item,
    this.customName = '',
    this.reason = '',
  });
}

/// 回收站对话框：展示被删记录，支持恢复/永久删除。
class RecycleBinDialog extends StatefulWidget {
  const RecycleBinDialog({super.key});

  @override
  State<RecycleBinDialog> createState() => _RecycleBinDialogState();
}

class _RecycleBinDialogState extends State<RecycleBinDialog> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await context.read<ScoreProvider>().fetchArchivedRecords();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  String _fmtTime(String iso) {
    if (iso.length < 19) return iso;
    return iso.replaceFirst('T', ' ').substring(0, 19);
  }

  String _scoreText(double v) {
    if (v > 0) return '+${v.toStringAsFixed(1)}';
    if (v < 0) return v.toStringAsFixed(1);
    return '0.0';
  }

  String _remainingLabel(String deletedAt) {
    final deleted = DateTime.tryParse(deletedAt);
    if (deleted == null) return '';
    final leftDays = 7 - DateTime.now().difference(deleted).inDays;
    if (leftDays <= 0) return '今日将自动清理';
    return '$leftDays 天后自动清理';
  }

  Future<void> _restore(Map<String, dynamic> item) async {
    final restored = await context
        .read<ScoreProvider>()
        .restoreRecordFromArchive(item['id'] as int);
    if (!mounted) return;
    if (restored == 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('目标学生/小组已不存在，无法恢复')));
      return;
    }
    setState(() => _items.removeWhere((e) => e['id'] == item['id']));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复该记录'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _permanentlyDelete(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('永久删除'),
        content: const Text('该记录将被永久删除，其修改记录也将一并清除，且不可恢复。确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<ScoreProvider>().permanentlyDeleteArchivedRecords([
      item['id'] as int,
    ]);
    if (!mounted) return;
    setState(() => _items.removeWhere((e) => e['id'] == item['id']));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('回收站'),
      content: SizedBox(
        width: 540,
        height: 440,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
            ? const Center(child: Text('回收站为空'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '被删除的记录保留 7 天，可恢复或手动永久删除。',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 8),

                  Expanded(
                    child: ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (_, i) {
                        final it = _items[i];
                        final score = (it['score'] as num).toDouble();
                        final name = it['target_name'] as String? ?? '(未知)';
                        final number =
                            it['target_student_number'] as String? ?? '';
                        // 姓名#学号（学号灰色）
                        final titleSpan = StudentDisplay.span(
                          name: name,
                          studentNumber: number,
                        );
                        final period = it['period'] as int? ?? 1;
                        final reason = it['reason'] as String? ?? '';
                        final deletedAt = it['deleted_at'] as String? ?? '';
                        // 该学生是否不参与小组总分统计
                        final notInGroupTotal =
                            it['target_type'] == 'student' &&
                            ((it['target_include_in_group_total'] as int?) ??
                                    1) ==
                                0;
                        final baseSubtitle = reason.isNotEmpty
                            ? '周期$period · $reason'
                            : '周期$period';
                        final subtitle =
                            '${notInGroupTotal ? '不参与小组总分 · ' : ''}$baseSubtitle\n删除于 ${_fmtTime(deletedAt)}';
                        return ListTile(
                          dense: true,
                          title: Row(
                            children: [
                              Expanded(
                                child: Text.rich(
                                  titleSpan,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                _scoreText(score),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: score >= 0
                                      ? Colors.green.shade700
                                      : Colors.red.shade700,
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _remainingLabel(deletedAt),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                              IconButton(
                                tooltip: '恢复',
                                icon: const Icon(Icons.restore, size: 20),
                                onPressed: () => _restore(it),
                              ),
                              IconButton(
                                tooltip: '永久删除',
                                icon: const Icon(
                                  Icons.delete_forever,
                                  size: 20,
                                ),
                                color: Colors.red,
                                onPressed: () => _permanentlyDelete(it),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
