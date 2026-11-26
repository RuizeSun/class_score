import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/student.dart';
import '../models/group.dart';
import '../database/database_helper.dart';
import '../services/backup_service.dart';
import '../services/import_service.dart';
import '../providers/group_provider.dart';
import '../widgets/glass_buttons.dart';
import '../widgets/glass_controls.dart';
import '../widgets/loading_state.dart';
import '../widgets/student_name_text.dart';

class StudentProvider extends ChangeNotifier {
  List<Student> _students = [];
  List<Student> get students => _students;

  List<Map<String, dynamic>> _studentsWithGroup = [];
  List<Map<String, dynamic>> get studentsWithGroup => _studentsWithGroup;

  int? _filterGroupId;
  int? get filterGroupId => _filterGroupId;

  Future<void> loadStudents({int? groupId}) async {
    _filterGroupId = groupId;
    final maps = await DatabaseHelper.instance.getStudentsWithGroupName(
      groupId: groupId,
    );
    _studentsWithGroup = maps;
    _students = maps.map((m) => Student.fromMap(m)).toList();
    notifyListeners();
  }

  Future<void> addStudent(
    String name,
    String studentNumber,
    int? groupId, {
    bool includeInGroupTotal = true,
  }) async {
    BackupService.instance.scheduleBackup();

    // If the student number is empty, generate the next sequential number.
    String finalStudentNumber = studentNumber.trim();
    if (finalStudentNumber.isEmpty) {
      finalStudentNumber = await DatabaseHelper.instance.getNextStudentNumber();
    }

    // groupId 为 null 表示"未分组"，使用 0 作为"未分组"的标记值
    await DatabaseHelper.instance.insertStudent({
      'name': name,
      'student_number': finalStudentNumber,
      'group_id': groupId ?? 0,
      'include_in_group_total': includeInGroupTotal ? 1 : 0,
    });
    await loadStudents(groupId: _filterGroupId);
  }

  Future<void> updateStudent(
    int id,
    String name,
    String studentNumber,
    int? groupId, {
    bool includeInGroupTotal = true,
  }) async {
    await BackupService.instance.createBackup();
    // groupId 为 null 表示"未分组"，使用 0 作为"未分组"的标记值
    await DatabaseHelper.instance.updateStudent(id, {
      'name': name,
      'student_number': studentNumber,
      'group_id': groupId ?? 0,
      'include_in_group_total': includeInGroupTotal ? 1 : 0,
    });
    await loadStudents(groupId: _filterGroupId);
  }

  Future<void> deleteStudent(int id) async {
    await BackupService.instance.createBackup(force: true);
    await DatabaseHelper.instance.deleteStudent(id);
    await loadStudents(groupId: _filterGroupId);
  }

  /// 批量删除学生：一次备份 + 一条 SQL 删完 + 一次重载。
  ///
  /// 逐条调用 [deleteStudent] 会让「备份 + 全量重载 + notifyListeners」
  /// 随人数线性增长（删 30 人 = 30 轮），因此批量删除统一走这里。
  Future<int> deleteStudents(Iterable<int> ids) async {
    final idList = ids.toSet().toList();
    if (idList.isEmpty) return 0;
    await BackupService.instance.createBackup(force: true);
    final deleted = await DatabaseHelper.instance.deleteStudents(idList);
    await loadStudents(groupId: _filterGroupId);
    return deleted;
  }

  /// 批量导入学生
  /// [overwrite] 是否覆盖现有数据（默认false，为true时先清空所有学生和分组）
  /// 返回成功导入的数量
  Future<int> batchImportStudents({
    required List<ImportedStudent> importedStudents,
    bool overwrite = false,
  }) async {
    if (importedStudents.isEmpty) return 0;

    // 覆盖导入会清空学生/分组/评分记录，属整库级破坏性操作：必须**先**有备份，
    // 所以这一条仍然 await（不能被调度器推到写入之后）。
    // 追加导入只是普通写入，走延后备份即可，不必挡在导入前面。
    if (overwrite) {
      await BackupService.instance.createBackup(force: true);
    } else {
      BackupService.instance.scheduleBackup();
    }

    final db = await DatabaseHelper.instance.database;
    int successCount = 0;

    await db.transaction((txn) async {
      // 如果是覆盖模式，先清空所有数据和分数记录
      if (overwrite) {
        // 删除所有分数记录
        await txn.delete('score_records');
        // 删除所有学生
        await txn.delete('students');
        // 删除所有分组
        await txn.delete('groups');
        // 重置自增ID
        await txn.execute(
          'DELETE FROM sqlite_sequence WHERE name IN ("score_records", "students", "groups")',
        );
      }

      // 分组表与「下一个学号」在整批导入里各读一次即可。
      //
      // 以前是每名学生都查一遍 groups 全表 + 一次 MAX(student_number)：
      // 导入 50 人就是 100 次多余查询，全部串行排在数据库上，
      // 整段导入期间界面看起来就是卡死。现在只在循环外读一次、循环内查内存。
      // 同名分组只认先出现的那个：旧实现用 firstWhere 取第一条，
      // 直接建 map 会保留最后一条，分组归属就会与以前不同。
      final groupRows = await txn.query('groups', orderBy: 'id');
      final groupIdByName = <String, int>{};
      for (final g in groupRows) {
        groupIdByName.putIfAbsent(g['name'] as String, () => g['id'] as int);
      }
      final maxNumberRow = await txn.rawQuery(
        'SELECT MAX(CAST(student_number AS INTEGER)) as max_num FROM students',
      );
      var nextStudentNumber =
          ((maxNumberRow.first['max_num'] as int?) ?? 0) + 1;

      for (final student in importedStudents) {
        try {
          // 解析小组名：命中已有分组就复用，否则建一个并记进内存表
          int? resolvedGroupId;
          final groupName = (student.groupName != null &&
                  student.groupName!.isNotEmpty)
              ? student.groupName!
              : '未分组';
          final existing = groupIdByName[groupName];
          if (existing != null) {
            resolvedGroupId = existing;
          } else {
            resolvedGroupId = await txn.insert('groups', {'name': groupName});
            groupIdByName[groupName] = resolvedGroupId;
          }

          // 处理学号：为空时按批内递增生成
          String? finalStudentNumber = student.studentNumber;
          if (finalStudentNumber == null || finalStudentNumber.isEmpty) {
            finalStudentNumber = (nextStudentNumber++).toString();
          } else {
            // 显式学号若比当前计数大，后续自动生成的学号要接着它往下排
            // （原来每条插入后都重查一次 MAX，这里用等价的内存推进）。
            // 与旧实现等价：旧实现每插一条就取 MAX(CAST(student_number AS
            // INTEGER))，而 SQLite 的 CAST 取的是最长数字前缀
            // (12abc 得到 12、3.5 得到 3、1e3 得到 1)，
            // 不是 int.tryParse 的严格整串解析。
            final explicit = _sqliteCastToInt(finalStudentNumber);
            if (explicit != null && explicit >= nextStudentNumber) {
              nextStudentNumber = explicit + 1;
            }
          }

          // 插入学生
          await txn.insert('students', {
            'name': student.name,
            'student_number': finalStudentNumber,
            'group_id': resolvedGroupId,
            'include_in_group_total': 1,
          });
          successCount++;
        } catch (_) {
          // 跳过出错的记录
          continue;
        }
      }
    });

    await loadStudents(groupId: _filterGroupId);
    return successCount;
  }

  /// 复刻 SQLite CAST(text AS INTEGER) 的取值：取最长数字前缀，
  /// 没有数字前缀则为 0；超出 64 位范围时按 SQLite 的规则夹到 INT64 边界。
  /// 用于让自动学号与旧实现的 MAX(CAST(...)) 一致。
  static int? _sqliteCastToInt(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^\s*([+-]?\d+)').firstMatch(value);
    if (match == null) return 0;
    final parsed = int.tryParse(match.group(1)!);
    if (parsed != null) return parsed;
    // 数字前缀长到溢出 int64：SQLite 会夹到边界而不是报错。
    return match.group(1)!.startsWith('-')
        ? -0x8000000000000000
        : 0x7FFFFFFFFFFFFFFF;
  }

  /// 批量将选中的学生添加到指定小组
  /// [studentIds] 要更新的学生ID列表
  /// [groupId] 目标小组ID（null表示移到"未分组"）
  Future<void> batchUpdateStudentsGroup({
    required List<int> studentIds,
    required int? groupId,
  }) async {
    if (studentIds.isEmpty) return;

    await BackupService.instance.createBackup();

    final db = await DatabaseHelper.instance.database;
    await db.transaction((txn) async {
      for (final id in studentIds) {
        await txn.update(
          'students',
          {'group_id': groupId},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });

    await loadStudents(groupId: _filterGroupId);
  }

  /// 显示批量添加到小组的对话框
  static Future<void> showBatchAddToGroupDialog(
    BuildContext context,
    List<Student> students,
  ) async {
    if (students.isEmpty) return;

    final groupProvider = context.read<GroupProvider>();
    final groups = groupProvider.groups;

    // 使用 nullable int? 作为值类型：非 null 表示小组 ID
    int? selectedGroupId;
    String getGroupName(int? groupId) {
      if (groupId == null) return '未分组';
      final group = groups.firstWhere(
        (g) => g.id == groupId,
        orElse: () => Group(id: null, name: '未分组'),
      );
      return group.name;
    }

    // 过滤掉数据库中名为"未分组"的分组
    final realGroups = groups.where((g) => g.name != '未分组').toList();

    // 如果没有实际分组，提示用户先创建分组
    if (realGroups.isEmpty) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('提示'),
          content: const Text('暂无小组，请先在设置中创建小组。'),
          actions: [
            GlassActionButton(
              onPressed: () => Navigator.pop(ctx),
              variant: GlassActionVariant.prominent,
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }

    // 默认选择第一个分组
    selectedGroupId = realGroups.first.id;

    // 构建下拉菜单项：只显示实际创建的小组
    final List<DropdownMenuItem<int?>> dropdownItems = realGroups
        .map((g) => DropdownMenuItem<int?>(value: g.id, child: Text(g.name)))
        .toList();

    // 显示多选学生列表的预览
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('批量添加到小组'),
          content: SizedBox(
            width: 450,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已选择 ${students.length} 名学生：',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 200,
                  child: ListView(
                    children: students.map((s) {
                      return ListTile(
                        dense: true,
                        // 姓名#学号（学号灰色）
                        title: StudentNameText(
                          name: s.name,
                          studentNumber: s.studentNumber,
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('选择目标小组：'),
                const SizedBox(height: 8),
                GlassDropdownField<int?>(
                  initialValue: selectedGroupId,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                  ),
                  items: dropdownItems,
                  onChanged: (v) {
                    setState(() {
                      selectedGroupId = v;
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            GlassActionButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            GlassActionButton(
              variant: GlassActionVariant.prominent,
              onPressed: () {
                final studentProvider = context.read<StudentProvider>();
                final groupName = getGroupName(selectedGroupId);

                // 获取学生ID列表
                final studentIds = students.map((s) => s.id!).toList();

                Navigator.pop(ctx); // 关闭对话框

                // 执行批量更新
                studentProvider.batchUpdateStudentsGroup(
                  studentIds: studentIds,
                  groupId: selectedGroupId,
                );

                // 显示成功消息
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '已成功将 ${students.length} 名学生移动到"$groupName"',
                      ),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              },
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  }

  /// 显示导入对话框
  static Future<void> showImportDialog(BuildContext context) async {
    final List<String> errorLogs = [];
    final List<ImportedStudent> students = [];

    // 解析已搬进后台 isolate，界面在解析期间不会冻结；
    // 这里**不加**忙碌遮罩：文件选择器是系统原生窗口，遮罩会一直盖在
    // 应用窗口上、与选择器同屏出现，反而更奇怪。
    final importedStudents = await ImportService.pickAndImport(
      errorLogs: errorLogs,
    );

    if (importedStudents == null) return; // 用户取消选择

    students.addAll(importedStudents);

    if (students.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('文件中未找到有效数据'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // 显示预览对话框
    if (context.mounted) {
      bool overwriteMode = false;
      final importedCount = await showDialog<int>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('导入学生预览'),
            content: SizedBox(
              width: 450,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('共找到 ${students.length} 条学生数据'),
                  const SizedBox(height: 16),
                  const Text(
                    '预览（前10条）：',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 300,
                    child: ListView(
                      children: students.take(10).map((s) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          // 姓名#学号（学号灰色），后接所属小组
                          child: Text.rich(
                            TextSpan(
                              children: [
                                StudentDisplay.span(
                                  name: s.name,
                                  studentNumber: s.studentNumber ?? '',
                                ),
                                if (s.groupName != null &&
                                    s.groupName!.isNotEmpty)
                                  TextSpan(text: '，小组: ${s.groupName}'),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  if (students.length > 10)
                    Text('... 还有 ${students.length - 10} 条'),
                  const SizedBox(height: 16),
                  GlassCheckboxTile(
                    title: const Text('覆盖导入（清空现有数据后导入）'),
                    subtitle: const Text(
                      '警告：将删除所有学生、分组和分数记录',
                      style: TextStyle(color: Colors.red),
                    ),
                    value: overwriteMode,
                    onChanged: (v) {
                      setDialogState(() {
                        overwriteMode = v;
                      });
                    },
                    dense: true,
                  ),
                ],
              ),
            ),
            actions: [
              GlassActionButton(
                onPressed: () => Navigator.pop(ctx, 0), // 取消
                child: const Text('取消'),
              ),
              GlassActionButton(
                variant: GlassActionVariant.prominent,
                onPressed: () => Navigator.pop(ctx, overwriteMode ? -1 : 1),
                child: Text(overwriteMode ? '确认覆盖导入' : '确认导入'),
              ),
            ],
          ),
        ),
      );

      if (importedCount == 0) return; // 用户取消

      // 执行导入。整批写入（覆盖模式还要清库 + 强制备份）在数据多时明显耗时，
      // 期间给出忙碌遮罩，避免看起来没反应、被连点两次。
      if (!context.mounted) return;
      final provider = context.read<StudentProvider>();
      final count = await runBusy(
        context,
        () => provider.batchImportStudents(
          importedStudents: students,
          overwrite: importedCount == -1,
        ),
        message: importedCount == -1 ? '正在覆盖导入…' : '正在导入学生…',
      );

      // 显示结果
      String message;
      Color backgroundColor;
      if (importedCount == -1) {
        // 覆盖模式
        if (count == students.length) {
          message = '覆盖导入成功：已清空旧数据并导入全部 $count 条学生数据';
          backgroundColor = Colors.green;
        } else {
          message = '覆盖导入完成：成功 $count 条';
          backgroundColor = Colors.orange;
        }
      } else {
        // 追加模式
        if (count == students.length) {
          message = '导入成功：全部 $count 条学生数据已导入';
          backgroundColor = Colors.green;
        } else if (count > 0) {
          message = '导入完成：成功 $count 条，跳过 ${students.length - count} 条（可能是重复学号）';
          backgroundColor = Colors.orange;
        } else {
          message = '导入失败：所有记录都被跳过（可能是学号重复）';
          backgroundColor = Colors.red;
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: backgroundColor,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}
