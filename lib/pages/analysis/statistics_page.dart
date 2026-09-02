import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/score_item.dart';
import '../../providers/score_provider.dart';
import '../../providers/score_item_provider.dart';
import '../../providers/group_provider.dart';
import '../../providers/student_provider.dart';
import '../../providers/auth_provider.dart';
import 'analysis_page.dart';
import 'ranking_summary_page.dart';

class StatisticsAnalysisPage extends StatefulWidget {
  const StatisticsAnalysisPage({super.key});

  @override
  State<StatisticsAnalysisPage> createState() => _StatisticsAnalysisPageState();
}

class _StatisticsAnalysisPageState extends State<StatisticsAnalysisPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // 切换到指定Tab的方法
  void switchToTab(int index) {
    _tabController.animateTo(index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 0,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '统计报表'),
            Tab(text: '记录管理'),
            Tab(text: '图表分析'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          StatisticsView(onSwitchToRecord: () => switchToTab(1)),
          RecordManagementView(),
          const AnalysisView(),
        ],
      ),
    );
  }
}

// ==================== 统计报表 ====================

class StatisticsView extends StatefulWidget {
  final VoidCallback? onSwitchToRecord;
  const StatisticsView({super.key, this.onSwitchToRecord});

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
          Center(
            child: SegmentedButton<bool>(
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
          // 高级查询按钮
          Center(
            child: OutlinedButton.icon(
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
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
            ),
          ),
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
                      final groupId = g['id'] as int;
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
                        onTap: () {
                          // 切换到记录管理Tab并筛选该小组
                          widget.onSwitchToRecord?.call();
                          context.read<ScoreProvider>().requestGroupFilter(
                            groupId,
                          );
                        },
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

// ==================== 记录管理 ====================

class RecordManagementView extends StatefulWidget {
  const RecordManagementView({super.key});

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GroupProvider>().loadGroups();
      context.read<StudentProvider>().loadStudents();
      context.read<ScoreItemProvider>().loadItems();
      _checkPendingGroupFilter();
      _loadRecords();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 检查待处理的小组筛选（从统计报表跳转）
    final pending = context.read<ScoreProvider>().pendingGroupFilter;
    if (pending != null && pending != _filterGroupId) {
      _filterGroupId = pending;
      _filterStudentId = null;
      context.read<ScoreProvider>().consumeGroupFilter();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
          _loadRecords();
        }
      });
    }
  }

  void _checkPendingGroupFilter() {
    final scoreProvider = context.read<ScoreProvider>();
    final pending = scoreProvider.pendingGroupFilter;
    if (pending != null && pending != _filterGroupId) {
      _filterGroupId = pending;
      _filterStudentId = null;
      scoreProvider.consumeGroupFilter();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存失败，请重试')),
      );
    }
  }
  /// 弹出补充/修改变动原因表单。返回 null 表示取消。
  Future<_SupplementResult?> _showSupplementFormDialog(
    List<Map<String, dynamic>> targets,
  ) async {
    final items = context.read<ScoreItemProvider>().items;
    final isBatch = targets.length > 1;
    // 单选时预填已有原因
    final initialReason =
        !isBatch ? (targets.first['reason'] as String? ?? '') : '';

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
      content = '所选评分项「${item.name}」的预设分值为 $presetLabel，'
          '与选中的 ${conflicting.length} 条记录当前分值不一致。\n\n'
          '请选择保留各记录当前分值，还是统一改为该评分项的预设分值 $presetLabel。';
    } else {
      final orig = (conflicting.first['score'] as num).toDouble();
      content = '所选评分项「${item.name}」的预设分值为 $presetLabel，'
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

  /// 批量删除确认并执行
  Future<void> _runBatchDelete(List<Map<String, dynamic>> targets) async {
    if (targets.isEmpty) return;
    final ids = targets.map((r) => r['id'] as int).toList();
    final isSingle = targets.length == 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isSingle ? '确认删除' : '批量删除'),
        content: Text(
          isSingle
              ? '确定删除这条评分记录吗？此操作不可撤销。'
              : '确定删除选中的 ${targets.length} 条评分记录吗？此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<ScoreProvider>().deleteScoreRecords(ids);
    if (!mounted) return;
    setState(() => _selectedRecordIds.removeAll(ids));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已删除 ${targets.length} 条评分记录'),
        duration: const Duration(seconds: 2),
      ),
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
  ) =>
      records.where((r) => _selectedRecordIds.contains(r['id'])).toList();

  /// 批量操作控制栏：非批量时显示「批量操作」入口，批量时显示选择信息与操作按钮
  Widget _buildBatchBar(List<Map<String, dynamic>> records) {
    if (!_batchMode) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _enterBatchMode,
            icon: const Icon(Icons.checklist, size: 18),
            label: const Text('批量操作'),
          ),
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
            onPressed:
                selected.isNotEmpty ? () => _runBatchDelete(selected) : null,
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
        // 筛选区域
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
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
              const SizedBox(width: 8),
              Expanded(
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
                        child: Text(
                          s.studentNumber.isNotEmpty
                              ? '${s.name} (${s.studentNumber})'
                              : s.name,
                        ),
                      ),
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
        // 批量操作控制栏
        if (isUnlocked && records.isNotEmpty) _buildBatchBar(records),

        // 记录列表
        Expanded(
          child: records.isEmpty
              ? const Center(child: Text('暂无评分记录'))
              : ListView.builder(
                  itemCount: records.length,
                  itemBuilder: (_, i) {
                    final r = records[i];
                    final recordId = r['id'] as int;
                    final isSelected = _selectedRecordIds.contains(recordId);
                    final score = (r['score'] as num).toDouble();
                    final isPositive = score >= 0;
                    final time = r['create_time'] as String;
                    // Format time display
                    final displayTime = time
                        .replaceFirst('T', ' ')
                        .substring(0, 19);

                    final studentNumber =
                        r['target_student_number'] as String? ?? '';
                    final titleText = studentNumber.isNotEmpty
                        ? '${r['target_name'] ?? '(未知)'} ($studentNumber)'
                        : '${r['target_name'] ?? '(未知)'}';

                    // 是否由快速评分产生
                    final isQuick = (r['is_quick'] as num? ?? 0) != 0;

                    // 构建原因/评分项文本
                    final scoreItemName = r['score_item_name'] as String? ?? '';
                    final customName = r['custom_name'] as String? ?? '';
                    final reason = r['reason'] as String? ?? '';

                    // 构建显示文本：同时显示评分项和变动原因
                    String? displayReason;
                    final hasScoreItem =
                        scoreItemName.isNotEmpty || customName.isNotEmpty;
                    final hasReason = reason.isNotEmpty;

                    if (hasScoreItem && hasReason) {
                      final itemText = scoreItemName.isNotEmpty
                          ? scoreItemName
                          : customName;
                      displayReason = '$itemText · $reason';
                    } else if (hasScoreItem) {
                      displayReason = scoreItemName.isNotEmpty
                          ? scoreItemName
                          : customName;
                    } else if (hasReason) {
                      displayReason = reason;
                    }

                    // 快速评分记录：标识来源，未填写原因时提示
                    if (isQuick) {
                      displayReason =
                          '快速评分 · ${displayReason?.isNotEmpty == true ? displayReason : '未填写原因'}';
                    }

                    // 构建subtitle内容
                    String subtitleContent;
                    if (displayReason != null && displayReason.isNotEmpty) {
                      subtitleContent = '$displayReason\n$displayTime';
                    } else {
                      subtitleContent = displayTime;
                    }

                    return ListTile(
                      leading: _batchMode
                          ? Checkbox(
                              value: isSelected,
                              onChanged: (_) =>
                                  _toggleRecordSelection(recordId),
                            )
                          : null,
                      selected: isSelected,
                      tileColor: _batchMode && isSelected
                          ? Colors.blueGrey.withValues(alpha: 0.08)
                          : null,
                      onTap: _batchMode
                          ? () => _toggleRecordSelection(recordId)
                          : null,
                      title: Text(titleText),
                      subtitle: Text(
                        subtitleContent,
                        maxLines:
                            displayReason != null && displayReason.isNotEmpty
                            ? 2
                            : 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            score.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isPositive ? Colors.green : Colors.red,
                            ),
                          ),
                          // 补充/修改变动原因（快速评分或缺失评分项的记录）
                          if (!_batchMode &&
                              isUnlocked &&
                              (isQuick || !hasScoreItem))
                            IconButton(
                              tooltip: hasReason ? '修改变动原因' : '补充变动原因',
                              icon: Icon(
                                hasReason
                                    ? Icons.edit_note
                                    : Icons.note_add,
                                size: 20,
                                color: Colors.blueGrey,
                              ),
                              onPressed: () => _runSupplementFlow([r]),
                            ),
                          // 单条删除（批量模式下交由批量删除处理）
                          if (!_batchMode && isUnlocked)
                            IconButton(
                              icon: const Icon(Icons.delete, size: 20),
                              onPressed: () => _runBatchDelete([r]),
                            ),
                        ],
                      ),
                    );
                  },
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

