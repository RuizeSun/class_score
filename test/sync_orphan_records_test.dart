import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// 删掉学生之后，他名下的评分记录怎么算？
///
/// v11 把删除改成墓碑，`ON DELETE CASCADE` 不再触发：记录还在表里，
/// target_id 指向一条墓碑行。如果这些"孤儿记录"继续参与统计，就会出现
/// 「名单里已经没有这个人，班级总分里却还算着他的分」。
///
/// 采用的规则：
/// - **统计口径（总分、分布、日均）一律排除**孤儿记录；
/// - **明细列表（评分变动记录）仍然展示**，历史不该凭空消失。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late DatabaseHelper helper;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_orphan');
    DatabaseHelper.dbDirOverride = root.path;
    helper = DatabaseHelper.instance;
  });

  tearDown(() async {
    await helper.closeDatabase();
    DatabaseHelper.dbDirOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('删学生后：统计不再计入他的分，但明细里仍然看得到', () async {
    final groupId = await helper.insertGroup({'name': '一班'});
    final keep = await helper.insertStudent({
      'name': '李四', 'student_number': '02', 'group_id': groupId,
    });
    final gone = await helper.insertStudent({
      'name': '张三', 'student_number': '01', 'group_id': groupId,
    });
    for (final (sid, score) in [(keep, 3.0), (gone, 100.0)]) {
      await helper.insertScoreRecord({
        'target_type': 'student', 'target_id': sid, 'score': score,
        'create_time': DateTime.now().toIso8601String(), 'period': 1,
      });
    }

    expect(
      (await helper.getAverageDailyScores())['total_positive'],
      103.0,
    );

    await helper.deleteStudent(gone);

    // 统计口径：100 分不再计入
    final avg = await helper.getAverageDailyScores();
    expect(
      avg['total_positive'],
      3.0,
      reason: '名单里已经没有张三，班级总分不能再算他的分',
    );
    final groups = await helper.getGroupTotalScores();
    expect(groups.single['total_score'], 3.0, reason: '与班级总分保持一致');

    // 明细列表：历史保留
    final details = await helper.getScoreRecordsAdvanced();
    expect(
      details,
      hasLength(2),
      reason: '评分变动记录是历史，不该因为删了人就不见了',
    );
  });

  test('删小组后：小组维度的统计也不计入它的分', () async {
    final groupId = await helper.insertGroup({'name': '二班'});
    final studentId = await helper.insertStudent({
      'name': '王五', 'student_number': '03', 'group_id': groupId,
    });
    await helper.insertScoreRecord({
      'target_type': 'group', 'target_id': groupId, 'score': 50.0,
      'create_time': DateTime.now().toIso8601String(), 'period': 1,
    });
    await helper.insertScoreRecord({
      'target_type': 'student', 'target_id': studentId, 'score': 5.0,
      'create_time': DateTime.now().toIso8601String(), 'period': 1,
    });

    expect((await helper.getAverageDailyScores())['total_positive'], 55.0);

    await helper.deleteGroup(groupId);

    // 小组本身及其成员都被墓碑化，两条记录都成了孤儿
    expect(
      (await helper.getAverageDailyScores())['total_positive'],
      0.0,
      reason: '小组和成员都删了，两条记录都不该再计入统计',
    );
  });
}
