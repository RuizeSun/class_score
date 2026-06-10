import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/score_provider.dart';
import '../../providers/student_provider.dart';
import '../../providers/auth_provider.dart';

class ScoreRecordsPage extends StatefulWidget {
  const ScoreRecordsPage({super.key});

  @override
  State<ScoreRecordsPage> createState() => _ScoreRecordsPageState();
}

class _ScoreRecordsPageState extends State<ScoreRecordsPage> {
  int? _filterStudentId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<StudentProvider>().loadStudents();
      context.read<ScoreProvider>().loadRecords(targetType: 'student');
    });
  }

  @override
  Widget build(BuildContext context) {
    final records = context.watch<ScoreProvider>().recordsWithName;
    final students = context.watch<StudentProvider>().students;
    final isUnlocked = context.watch<AuthProvider>().isUnlocked;

    return Scaffold(
      appBar: AppBar(toolbarHeight: 0),
      body: Column(
        children: [
          // Filters（仅学生）
          Padding(
            padding: const EdgeInsets.all(8.0),
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
                context.read<ScoreProvider>().loadRecords(
                  targetType: 'student',
                  targetId: v,
                );
              },
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

                      // 优先显示评分项名称或原因
                      String? displayReason;
                      if (scoreItemName.isNotEmpty) {
                        displayReason = scoreItemName;
                      } else if (customName.isNotEmpty) {
                        displayReason = customName;
                      } else if (reason.isNotEmpty) {
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
