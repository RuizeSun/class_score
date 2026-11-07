import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// v11 墓碑改造对「既有功能」的回归面。
///
/// 删除从物理删除变成墓碑之后，有两类既有流程会**直接失效**：
/// 1. 回收站恢复：原行仍在库里（只是 deleted_at 非空），用原主键重新插入会撞主键；
/// 2. 覆盖导入：旧行变成墓碑但唯一索引还在，新学生沿用同一学号会撞唯一索引，
///    而导入循环里的 catch 会把异常默默吞掉——表现为"一条都没导进去"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late DatabaseHelper helper;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_regress');
    DatabaseHelper.dbDirOverride = root.path;
    helper = DatabaseHelper.instance;
  });

  tearDown(() async {
    await helper.closeDatabase();
    DatabaseHelper.dbDirOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<int> seedStudent(String number, {String name = '张三'}) async {
    final groupId = await helper.getOrCreateDefaultGroupId();
    return helper.insertStudent({
      'name': name,
      'student_number': number,
      'group_id': groupId,
    });
  }

  test('回收站：删除 → 恢复，记录重新出现在明细里', () async {
    final studentId = await seedStudent('01');
    final recordId = await helper.insertScoreRecord({
      'target_type': 'student',
      'target_id': studentId,
      'score': 3,
      'reason': '值日',
      'create_time': DateTime.now().toIso8601String(),
      'period': 1,
    });

    // 删除走回收站（这是 UI 上真正的"删除"路径）
    await helper.archiveScoreRecords([recordId], DateTime.now().toIso8601String());
    expect(await helper.getScoreRecordsAdvanced(), isEmpty);

    final archived = await helper.getArchivedRecords();
    expect(archived, hasLength(1), reason: '记录应当进了回收站');

    // 恢复：必须能成功，且记录回到明细里
    final restored = await helper.restoreArchivedRecord(archived.single['id'] as int);
    expect(restored, 1, reason: '回收站恢复必须成功');
    final rows = await helper.getScoreRecordsAdvanced();
    expect(rows, hasLength(1), reason: '恢复后记录应当重新可见');
    expect(rows.single['reason'], '值日');
  });

  test('删除学生后，学号可以被新学生重新使用（唯一索引不能被墓碑占着）', () async {
    final groupId = await helper.getOrCreateDefaultGroupId();
    final oldId = await helper.insertStudent({
      'name': '李四',
      'student_number': '07',
      'group_id': groupId,
    });
    await helper.deleteStudent(oldId);

    // 同一个学号在"新学生"身上必须能落库
    final newId = await helper.insertStudent({
      'name': '王五',
      'student_number': '07',
      'group_id': groupId,
    });
    expect(newId, isPositive);
    final students = await helper.getStudents();
    expect(students, hasLength(1));
    expect(students.single['name'], '王五');
  });
}
