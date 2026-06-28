import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/score_provider.dart';
import '../../providers/student_provider.dart';
import '../../providers/group_provider.dart';
import '../../providers/auth_provider.dart';

class ScoreRecordsPage extends StatefulWidget {
  const ScoreRecordsPage({super.key});

  @override
  State<ScoreRecordsPage> createState() => _ScoreRecordsPageState();
}

class _ScoreRecordsPageState extends State<ScoreRecordsPage> {
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

  /// 检查是否有待处理的小组筛选（来自统计分析页面点击小组跳转）
  void _checkPendingGroupFilter() {
    final scoreProvider = context.read<ScoreProvider>();
    final pending = scoreProvider.pendingGroupFilter;
    if (pending != null) {
      _filterGroupId = pending;
      _filterStudentId = null;
      scoreProvider.consumeGroupFilter();
    }
  }

  void _loadRecords() {
    final scoreProvider = context.read<ScoreProvider>();
    if (_filterGroupId != null) {
      if (_filterStudentId != null) {
        // 选了小组 + 具体学生 → 只查该学生的记录
        scoreProvider.loadRecords(
          targetType: 'student',
          targetId: _filterStudentId,
        );
      } else {
        // 选了小组 + 全部学生 → 查该小组所有成员的记录
        scoreProvider.loadRecords(groupId: _filterGroupId);
      }
    } else {
      // 全部小组
      if (_filterStudentId != null) {
        // 全部小组 + 具体学生 → 只查该学生的记录
        scoreProvider.loadRecords(
          targetType: 'student',
          targetId: _filterStudentId,
        );
      } else {
        // 全部小组 + 全部学生 → 查所有学生记录
        scoreProvider.loadRecords(targetType: 'student');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scoreProvider = context.watch<ScoreProvider>();
    final records = scoreProvider.recordsWithName;
    final allStudents = context.watch<StudentProvider>().students;
    final groups = context.watch<GroupProvider>().groups;
    final isUnlocked = context.watch<AuthProvider>().isUnlocked;

    // 每次 build 时检测是否有待处理的筛选，并延迟应用（避免 build 中触发 setState）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = scoreProvider.pendingGroupFilter;
      if (pending != null && pending != _filterGroupId) {
        setState(() {
          _filterGroupId = pending;
          _filterStudentId = null;
        });
        scoreProvider.consumeGroupFilter();
        _loadRecords();
      }
    });

    // 根据所选小组过滤学生列表
    final students = _filterGroupId != null
        ? allStudents.where((s) => s.groupId == _filterGroupId).toList()
        : allStudents;

    return Scaffold(
      appBar: AppBar(toolbarHeight: 0),
      body: Column(
        children: [
          // Filters（一行两个：小组 + 学生）
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int?>(
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
                        (g) =>
                            DropdownMenuItem(value: g.id, child: Text(g.name)),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _filterGroupId = v;
                        // 切换小组后，清除学生筛选（因为可能选了另一个小组的学生）
                        _filterStudentId = null;
                      });
                      _loadRecords();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<int?>(
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
          // Records list
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

                      // 构建原因/评分项文本
                      final scoreItemName =
                          r['score_item_name'] as String? ?? '';
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
      ),
    );
  }
}
