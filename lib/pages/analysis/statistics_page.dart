import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/score_provider.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GroupProvider>().loadGroups();
      context.read<StudentProvider>().loadStudents();
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

  /// 弹出对话框，用于补充/修改快速评分记录的变动原因
  Future<void> _showEditReasonDialog(
    BuildContext dialogContext, {
    required int recordId,
    required String currentReason,
  }) async {
    final controller = TextEditingController(text: currentReason);
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (ctx) => AlertDialog(
        title: const Text('补充变动原因'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '为该条快速评分记录补充变动原因（如：课堂表现加分、作业未交扣分等）。',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '变动原因',
                border: OutlineInputBorder(),
                hintText: '请输入变动原因',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    final text = controller.text.trim();
    if (confirmed == true && text.isNotEmpty) {
      final scoreProvider = context.read<ScoreProvider>();
      await scoreProvider.updateScoreRecordReason(recordId, text);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('变动原因已保存'), duration: Duration(seconds: 2)),
      );
    }
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
        // 记录列表
        Expanded(
          child: records.isEmpty
              ? const Center(child: Text('暂无评分记录'))
              : ListView.builder(
                  itemCount: records.length,
                  itemBuilder: (_, i) {
                    final r = records[i];
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
                          // 快速评分记录：解锁状态下可补充/修改变动原因
                          if (isUnlocked && isQuick)
                            IconButton(
                              tooltip: reason.isNotEmpty ? '修改变动原因' : '补充变动原因',
                              icon: Icon(
                                reason.isNotEmpty
                                    ? Icons.edit_note
                                    : Icons.note_add,
                                size: 20,
                                color: Colors.blueGrey,
                              ),
                              onPressed: () {
                                _showEditReasonDialog(
                                  context,
                                  recordId: r['id'] as int,
                                  currentReason: reason,
                                );
                              },
                            ),
                          if (isUnlocked)
                            IconButton(
                              icon: const Icon(Icons.delete, size: 20),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('确认删除'),
                                    content: const Text('确定删除这条评分记录吗？'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('取消'),
                                      ),
                                      TextButton(
                                        onPressed: () {
                                          context
                                              .read<ScoreProvider>()
                                              .deleteScoreRecord(
                                                r['id'] as int,
                                              );
                                          Navigator.pop(ctx);
                                        },
                                        child: const Text('删除'),
                                      ),
                                    ],
                                  ),
                                );
                              },
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
