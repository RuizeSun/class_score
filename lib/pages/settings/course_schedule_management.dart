import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';

/// Show dialog to add or edit a course schedule.
void showCourseScheduleDialog(
  BuildContext context, {
  Map<String, dynamic>? schedule,
}) {
  int selectedWeekday = schedule?['weekday'] as int? ?? 1;
  final nameController = TextEditingController(
    text: schedule?['course_name'] as String? ?? '',
  );
  final startController = TextEditingController(
    text: schedule?['start_time'] as String? ?? '',
  );
  final endController = TextEditingController(
    text: schedule?['end_time'] as String? ?? '',
  );

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: Text(schedule == null ? '添加课程' : '编辑课程'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<int>(
              value: selectedWeekday,
              decoration: const InputDecoration(
                labelText: '星期',
                border: OutlineInputBorder(),
              ),
              items: [1, 2, 3, 4, 5, 6, 7]
                  .map(
                    (d) => DropdownMenuItem(
                      value: d,
                      child: Text(AuthProvider.weekdayNames[d] ?? '周$d'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setDialogState(() => selectedWeekday = v!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '课程名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: startController,
                    decoration: const InputDecoration(
                      labelText: '开始时间',
                      border: OutlineInputBorder(),
                      hintText: '08:00',
                    ),
                    keyboardType: TextInputType.datetime,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: endController,
                    decoration: const InputDecoration(
                      labelText: '结束时间',
                      border: OutlineInputBorder(),
                      hintText: '09:40',
                    ),
                    keyboardType: TextInputType.datetime,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final name = nameController.text.trim();
              final start = startController.text.trim();
              final end = endController.text.trim();
              if (name.isNotEmpty && start.isNotEmpty && end.isNotEmpty) {
                final map = {
                  'weekday': selectedWeekday,
                  'course_name': name,
                  'start_time': start,
                  'end_time': end,
                };
                if (schedule == null) {
                  context.read<AuthProvider>().addCourseSchedule(map);
                } else {
                  context.read<AuthProvider>().updateCourseSchedule(
                    schedule['id'] as int,
                    map,
                  );
                }
                Navigator.pop(ctx);
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

/// 可嵌入 SettingsHubPage 的课程表管理视图（不包含 Scaffold/AppBar）。
class CourseScheduleManagementView extends StatelessWidget {
  const CourseScheduleManagementView({
    super.key,
    required this.onShowCourseDialog,
    required this.isUnlocked,
  });

  final void Function({Map<String, dynamic>? schedule}) onShowCourseDialog;
  final bool isUnlocked;

  @override
  Widget build(BuildContext context) {
    final schedules = context.watch<AuthProvider>().courseSchedules;

    // Group by weekday
    final Map<int, List<Map<String, dynamic>>> grouped = {};
    for (final s in schedules) {
      final wd = s['weekday'] as int;
      grouped.putIfAbsent(wd, () => []).add(s);
    }

    return Stack(
      children: [
        schedules.isEmpty
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.calendar_month, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('暂无课程安排'),
                    SizedBox(height: 8),
                    Text('解锁后可编辑课程', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              )
            : ListView(
                children: [1, 2, 3, 4, 5, 6, 7]
                    .where((wd) => grouped.containsKey(wd))
                    .map((wd) {
                      final daySchedules = grouped[wd]!;
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: ExpansionTile(
                          title: Text(
                            AuthProvider.weekdayNames[wd] ?? '周$wd',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text('${daySchedules.length} 节课'),
                          children: daySchedules.map((s) {
                            return ListTile(
                              title: Text(s['course_name'] as String),
                              subtitle: Text(
                                '${s['start_time']} - ${s['end_time']}',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 20),
                                    onPressed: isUnlocked
                                        ? () => onShowCourseDialog(schedule: s)
                                        : null,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete, size: 20),
                                    onPressed: isUnlocked
                                        ? () {
                                            showDialog(
                                              context: context,
                                              builder: (ctx) => AlertDialog(
                                                title: const Text('确认删除'),
                                                content: Text(
                                                  '确定删除课程"${s['course_name']}"吗？',
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(ctx),
                                                    child: const Text('取消'),
                                                  ),
                                                  TextButton(
                                                    onPressed: () {
                                                      context
                                                          .read<AuthProvider>()
                                                          .deleteCourseSchedule(
                                                            s['id'] as int,
                                                          );
                                                      Navigator.pop(ctx);
                                                    },
                                                    child: const Text('删除'),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }
                                        : null,
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      );
                    })
                    .toList(),
              ),
        if (isUnlocked)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              heroTag: 'course_schedule_fab',
              onPressed: () => onShowCourseDialog(),
              child: const Icon(Icons.add),
            ),
          ),
      ],
    );
  }
}
