import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/student.dart';
import '../../models/group.dart';
import '../../providers/student_provider.dart';
import '../../providers/group_provider.dart';
import '../../providers/auth_provider.dart';

/// Show dialog to add or edit a student.
void showStudentDialog(BuildContext context, {Student? student}) {
  final nameController = TextEditingController(text: student?.name ?? '');
  final studentNumberController = TextEditingController(
    text: student?.studentNumber ?? '',
  );
  final groups = context.read<GroupProvider>().groups;

  // 查找数据库中"未分组"分组的 id
  final defaultGroupId = groups
      .firstWhere(
        (g) => g.name == '未分组',
        orElse: () => Group(id: -1, name: '未分组'),
      )
      .id;

  // 如果学生属于"未分组"分组或 group_id 为 0，将 selectedGroupId 设为 null
  int? selectedGroupId;
  if (student == null) {
    selectedGroupId = null;
  } else if (student.groupId == null || student.groupId == 0) {
    selectedGroupId = null;
  } else if (student.groupId == defaultGroupId) {
    selectedGroupId = null;
  } else {
    selectedGroupId = student.groupId;
  }

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: Text(student == null ? '添加学生' : '编辑学生'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '学生姓名'),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: studentNumberController,
              decoration: const InputDecoration(
                labelText: '学号',
                hintText: '请输入唯一学号（留空则自动生成）',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int?>(
              initialValue: selectedGroupId,
              decoration: const InputDecoration(labelText: '所属小组'),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('未分组')),
                ...groups
                    .where((g) => g.name != '未分组')
                    .map(
                      (g) => DropdownMenuItem(value: g.id, child: Text(g.name)),
                    ),
              ],
              onChanged: (v) {
                setDialogState(() {
                  selectedGroupId = v;
                });
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final name = nameController.text.trim();
              final studentNumber = studentNumberController.text.trim();
              if (name.isNotEmpty) {
                if (student == null) {
                  await context.read<StudentProvider>().addStudent(
                    name,
                    studentNumber,
                    selectedGroupId,
                  );
                  // 可能会自动创建"未分组"默认分组，因此这里刷新一次分组列表。
                  await context.read<GroupProvider>().loadGroups();
                } else {
                  await context.read<StudentProvider>().updateStudent(
                    student.id!,
                    name,
                    studentNumber,
                    selectedGroupId,
                  );
                  await context.read<GroupProvider>().loadGroups();
                }
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

class StudentManagementView extends StatefulWidget {
  const StudentManagementView({super.key, required this.onShowStudentDialog});

  final void Function({Student? student}) onShowStudentDialog;

  @override
  _StudentManagementViewState createState() => _StudentManagementViewState();
}

class _StudentManagementViewState extends State<StudentManagementView> {
  Set<int> _selectedStudentIds = {};
  bool _isSelectionMode = false;

  void _toggleSelection(int studentId) {
    setState(() {
      if (_selectedStudentIds.contains(studentId)) {
        _selectedStudentIds.remove(studentId);
        if (_selectedStudentIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedStudentIds.add(studentId);
        _isSelectionMode = true;
      }
    });
  }

  void _selectAll(List<Map<String, dynamic>> students) {
    setState(() {
      if (_selectedStudentIds.length == students.length) {
        _selectedStudentIds.clear();
        _isSelectionMode = _selectedStudentIds.isNotEmpty;
      } else {
        _selectedStudentIds = students.map((s) => s['id'] as int).toSet();
        _isSelectionMode = true;
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedStudentIds.clear();
      _isSelectionMode = false;
    });
  }

  void _showBatchAddToGroupDialog() {
    final studentProvider = context.read<StudentProvider>();
    final selectedStudents = studentProvider.students.where((s) {
      return _selectedStudentIds.contains(s.id);
    }).toList();

    if (selectedStudents.isNotEmpty) {
      StudentProvider.showBatchAddToGroupDialog(context, selectedStudents);
    }
  }

  void _batchDeleteStudents() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认批量删除'),
        content: Text('确定删除选中的 ${_selectedStudentIds.length} 名学生吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final provider = context.read<StudentProvider>();
              for (final id in _selectedStudentIds) {
                await provider.deleteStudent(id);
              }
              if (context.mounted) {
                _clearSelection();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已删除选中的学生'),
                    backgroundColor: Colors.orange,
                  ),
                );
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final students = context.watch<StudentProvider>().studentsWithGroup;
    final groups = context.watch<GroupProvider>().groups;
    final filterGroupId = context.watch<StudentProvider>().filterGroupId;
    final isUnlocked = context.watch<AuthProvider>().isUnlocked;

    return Stack(
      children: [
        Column(
          children: [
            // Filter by group and batch operations
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  // Filter by group dropdown
                  Expanded(
                    child: DropdownButtonFormField<int?>(
                      initialValue: filterGroupId,
                      decoration: const InputDecoration(
                        labelText: '筛选小组',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
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
                        _clearSelection();
                        context.read<StudentProvider>().loadStudents(
                          groupId: v,
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Batch operation button
                  if (isUnlocked && _isSelectionMode)
                    FilledButton.icon(
                      onPressed: _showBatchAddToGroupDialog,
                      icon: const Icon(Icons.group_add),
                      label: const Text('添加到小组'),
                    ),
                  if (isUnlocked && _isSelectionMode)
                    SizedBox(
                      width: 80,
                      child: FilledButton.icon(
                        onPressed: _batchDeleteStudents,
                        icon: const Icon(Icons.delete),
                        label: const Text('删除'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                        ),
                      ),
                    ),
                  if (_isSelectionMode)
                    TextButton.icon(
                      onPressed: _clearSelection,
                      icon: const Icon(Icons.close),
                      label: const Text('取消选择'),
                    ),
                ],
              ),
            ),
            // Selection info bar
            if (_isSelectionMode)
              Container(
                color: Colors.blue.shade50,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.blue.shade700),
                    const SizedBox(width: 8),
                    Text(
                      '已选择 ${_selectedStudentIds.length} 名学生',
                      style: TextStyle(
                        color: Colors.blue.shade700,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => _selectAll(students),
                      child: _selectedStudentIds.length == students.length
                          ? const Text('取消全选')
                          : const Text('全选'),
                    ),
                  ],
                ),
              ),
            // Student list
            Expanded(
              child: students.isEmpty
                  ? const Center(child: Text('暂无学生'))
                  : ListView.builder(
                      itemCount: students.length,
                      itemBuilder: (_, i) {
                        final s = students[i];
                        final studentId = s['id'] as int;
                        final isSelected = _selectedStudentIds.contains(
                          studentId,
                        );
                        return ListTile(
                          leading: isUnlocked
                              ? Checkbox(
                                  value: isSelected,
                                  onChanged: (_) => _toggleSelection(studentId),
                                )
                              : null,
                          title: Text(s['name'] as String),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(s['group_name'] as String? ?? ''),
                              if ((s['student_number'] as String?)
                                      ?.isNotEmpty ==
                                  true)
                                Text(
                                  '学号: ${s['student_number']}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!_isSelectionMode && isUnlocked)
                                IconButton(
                                  icon: const Icon(Icons.edit),
                                  onPressed: () {
                                    widget.onShowStudentDialog(
                                      student: Student(
                                        id: s['id'] as int,
                                        name: s['name'] as String,
                                        studentNumber:
                                            (s['student_number'] as String?) ??
                                            '',
                                        groupId: s['group_id'] as int?,
                                      ),
                                    );
                                  },
                                ),
                              if (!_isSelectionMode && isUnlocked)
                                IconButton(
                                  icon: const Icon(Icons.delete),
                                  onPressed: () {
                                    showDialog(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('确认删除'),
                                        content: Text('确定删除学生"${s['name']}"吗？'),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(ctx),
                                            child: const Text('取消'),
                                          ),
                                          TextButton(
                                            onPressed: () {
                                              context
                                                  .read<StudentProvider>()
                                                  .deleteStudent(
                                                    s['id'] as int,
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
        if (isUnlocked && !_isSelectionMode)
          Positioned(
            right: 16,
            bottom: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Quick filter to unassigned students button
                FloatingActionButton(
                  heroTag: 'filter_unassigned',
                  mini: true,
                  onPressed: () {
                    context.read<StudentProvider>().loadStudents(groupId: null);
                  },
                  tooltip: '查看未分组学生',
                  child: const Icon(Icons.filter_list),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'student_fab',
                  onPressed: () => widget.onShowStudentDialog(),
                  child: const Icon(Icons.add),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
