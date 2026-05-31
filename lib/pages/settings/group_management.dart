import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/group.dart';
import '../../providers/group_provider.dart';
import '../../providers/student_provider.dart';
import '../../providers/auth_provider.dart';
import '../../database/database_helper.dart';

/// Show dialog to add or edit a group.
void showGroupDialog(BuildContext context, {Group? group}) {
  final controller = TextEditingController(text: group?.name ?? '');
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(group == null ? '添加小组' : '编辑小组'),
      content: TextField(
        controller: controller,
        decoration: const InputDecoration(labelText: '小组名称'),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final name = controller.text.trim();
            if (name.isNotEmpty) {
              // 禁止创建名为"未分组"的分组
              if (group == null && name == '未分组') {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('不能创建名为"未分组"的分组，系统已内置该默认分组'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                }
                return;
              }
              if (name == '未分组' && group != null) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('不能将分组名称修改为"未分组"，这是系统保留名称'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                }
                return;
              }
              if (group == null) {
                context.read<GroupProvider>().addGroup(name);
              } else {
                context.read<GroupProvider>().updateGroup(group.id!, name);
              }
              Navigator.pop(ctx);
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

/// Show a simple dialog listing members of a group.
Future<void> showGroupMembers(BuildContext context, Group group) async {
  final students = await DatabaseHelper.instance.getStudentsWithGroupName(
    groupId: group.id,
  );
  if (!context.mounted) return;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${group.name} - 成员列表'),
      content: SizedBox(
        width: double.maxFinite,
        child: students.isEmpty
            ? const Text('暂无成员')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: students.length,
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  title: Text(students[i]['name'] as String),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// Show a rich group members dialog with batch selection and move support.
Future<void> showGroupMembersWithBatch(
  BuildContext context,
  Group group,
) async {
  final students = await DatabaseHelper.instance.getStudentsWithGroupName(
    groupId: group.id,
  );
  if (!context.mounted) return;

  final allGroups = await DatabaseHelper.instance.getGroups();

  showDialog(
    context: context,
    builder: (ctx) => _GroupMembersDialog(
      group: group,
      students: students,
      allGroups: allGroups,
    ),
  );
}

/// 小组成员对话框 - 支持多选和批量移动
class _GroupMembersDialog extends StatefulWidget {
  final Group group;
  final List<Map<String, dynamic>> students;
  final List<Map<String, dynamic>> allGroups;

  const _GroupMembersDialog({
    required this.group,
    required this.students,
    required this.allGroups,
  });

  @override
  State<_GroupMembersDialog> createState() => _GroupMembersDialogState();
}

class _GroupMembersDialogState extends State<_GroupMembersDialog> {
  Set<int> _selectedStudentIds = {};
  bool _isSelectionMode = false;
  int? _targetGroupId;

  bool get _isUnassignedOptionSelected => _targetGroupId == null;

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

  void _selectAll() {
    setState(() {
      if (_selectedStudentIds.length == widget.students.length) {
        _selectedStudentIds.clear();
        _isSelectionMode = false;
      } else {
        _selectedStudentIds = widget.students
            .map((s) => s['id'] as int)
            .toSet();
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

  Future<void> _batchMoveStudents() async {
    if (_selectedStudentIds.isEmpty || _targetGroupId == null) return;

    final studentProvider = context.read<StudentProvider>();
    await studentProvider.batchUpdateStudentsGroup(
      studentIds: _selectedStudentIds.toList(),
      groupId: _targetGroupId,
    );

    if (context.mounted) {
      Navigator.pop(context);
      context.read<GroupProvider>().loadGroups();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已成功将 ${_selectedStudentIds.length} 名学生移动到'
            '${_isUnassignedOptionSelected ? "未分组" : widget.allGroups.firstWhere((g) => g['id'] == _targetGroupId, orElse: () => {'name': '未知'})['name']}',
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUnlocked = context.watch<AuthProvider>().isUnlocked;

    return AlertDialog(
      title: Row(
        children: [
          Text('${widget.group.name} - 成员列表'),
          if (isUnlocked && widget.students.isNotEmpty) const Spacer(),
          if (isUnlocked && widget.students.isNotEmpty)
            TextButton(
              onPressed: _isSelectionMode ? _clearSelection : _selectAll,
              child: Text(_isSelectionMode ? '取消选择' : '全选'),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isSelectionMode) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Row(
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
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '选择目标小组：',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: RadioListTile<int?>(
                            title: const Text('未分组'),
                            value: null,
                            groupValue: _targetGroupId,
                            onChanged: (v) {
                              setState(() {
                                _targetGroupId = v;
                              });
                            },
                            dense: true,
                          ),
                        ),
                      ],
                    ),
                    ...widget.allGroups
                        .where((g) => g['id'] != widget.group.id)
                        .map(
                          (g) => Row(
                            children: [
                              Expanded(
                                child: RadioListTile<int?>(
                                  title: Text(g['name'] as String),
                                  value: g['id'] as int?,
                                  groupValue: _targetGroupId,
                                  onChanged: (v) {
                                    setState(() {
                                      _targetGroupId = v;
                                    });
                                  },
                                  dense: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        FilledButton.icon(
                          onPressed: _targetGroupId != null
                              ? _batchMoveStudents
                              : null,
                          icon: const Icon(Icons.group_add),
                          label: const Text('移动到所选小组'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            widget.students.isEmpty
                ? const Text('暂无成员')
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: widget.students.length,
                    itemBuilder: (_, i) {
                      final s = widget.students[i];
                      final studentId = s['id'] as int;
                      final isSelected = _selectedStudentIds.contains(
                        studentId,
                      );
                      return CheckboxListTile(
                        dense: true,
                        value: isSelected,
                        onChanged: isUnlocked
                            ? (_) => _toggleSelection(studentId)
                            : null,
                        title: Text(s['name'] as String),
                        subtitle:
                            s['student_number'] != null &&
                                (s['student_number'] as String).isNotEmpty
                            ? Text(
                                '学号: ${s['student_number']}',
                                style: const TextStyle(fontSize: 12),
                              )
                            : null,
                      );
                    },
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

/// 可嵌入 SettingsHubPage 的分组管理视图（不包含 Scaffold/AppBar）。
class GroupManagementView extends StatelessWidget {
  const GroupManagementView({
    super.key,
    required this.onShowGroupDialog,
    required this.onShowGroupMembers,
  });

  final void Function({Group? group}) onShowGroupDialog;
  final void Function(Group group) onShowGroupMembers;

  @override
  Widget build(BuildContext context) {
    final groups = context.watch<GroupProvider>().groups;
    final isUnlocked = context.watch<AuthProvider>().isUnlocked;

    return Stack(
      children: [
        groups.isEmpty
            ? const Center(child: Text('暂无分组，点击右下角添加'))
            : ListView.builder(
                itemCount: groups.length,
                itemBuilder: (_, i) {
                  final group = groups[i];
                  return ListTile(
                    title: Text(group.name),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.group),
                          tooltip: '查看成员',
                          onPressed: () => onShowGroupMembers(group),
                        ),
                        if (isUnlocked)
                          IconButton(
                            icon: const Icon(Icons.edit),
                            onPressed: () => onShowGroupDialog(group: group),
                          ),
                        if (isUnlocked)
                          IconButton(
                            icon: const Icon(Icons.delete),
                            onPressed: () {
                              if (group.name == '未分组') {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('不能删除默认分组"未分组"'),
                                    backgroundColor: Colors.orange,
                                  ),
                                );
                                return;
                              }
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('确认删除'),
                                  content: Text('确定删除"${group.name}"及其所有学生吗？'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx),
                                      child: const Text('取消'),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        context
                                            .read<GroupProvider>()
                                            .deleteGroup(group.id!);
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
        if (isUnlocked)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              heroTag: 'group_fab',
              onPressed: () => onShowGroupDialog(),
              child: const Icon(Icons.add),
            ),
          ),
      ],
    );
  }
}
