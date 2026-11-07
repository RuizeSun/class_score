import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 墓碑回归扫描：v11 把删除从「物理删除」改成了「墓碑（deleted_at）」。
///
/// 只要有任意一条既有查询漏掉 `deleted_at IS NULL`，被删掉的学生 / 小组 /
/// 记录就会重新出现在界面上。这类回归在日常点几下是看不出来的
/// （要删一次、重启一次才会显形），所以这里把 DatabaseHelper 里所有会
/// 返回业务行的入口都过一遍。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory root;
  late DatabaseHelper helper;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_tombstone');
    DatabaseHelper.dbDirOverride = root.path;
    helper = DatabaseHelper.instance;
  });

  tearDown(() async {
    await helper.closeDatabase();
    DatabaseHelper.dbDirOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 一组最小可用数据：小组 + 学生 + 评分项 + 评分记录。
  Future<Map<String, int>> seed() async {
    final groupId = await helper.insertGroup({'name': '一班'});
    final studentId = await helper.insertStudent({
      'name': '张三',
      'student_number': '01',
      'group_id': groupId,
    });
    final itemId = await helper.insertScoreItem({
      'name': '课堂表现',
      'default_score': 1,
      'description': '',
    });
    final recordId = await helper.insertScoreRecord({
      'target_type': 'student',
      'target_id': studentId,
      'score': 5,
      'reason': '回答问题',
      'score_item_id': itemId,
      'create_time': DateTime.now().toIso8601String(),
      'period': 1,
    });
    return {
      'group': groupId,
      'student': studentId,
      'item': itemId,
      'record': recordId,
    };
  }

  test('删除小组：所有小组相关查询都不再返回它', () async {
    final ids = await seed();
    await helper.deleteGroup(ids['group']!);

    final db = await helper.database;
    expect(
      (await db.query('groups')).single['deleted_at'],
      isNotNull,
      reason: '墓碑行必须留在库里（这是同步收敛的前提）',
    );
    expect(await helper.getGroups(), isEmpty);
    expect(await helper.getGroupTotalScores(), isEmpty);
    expect(
      await helper.getGroupTotalScoresByPeriodRange(startPeriod: 1, endPeriod: 1),
      isEmpty,
    );
  });

  test('删除学生：列表、连表、统计、学号分配都不再看到它', () async {
    final ids = await seed();
    await helper.deleteStudent(ids['student']!);

    expect(await helper.getStudents(), isEmpty);
    expect(await helper.getStudentsWithGroupName(), isEmpty);
    expect(await helper.getStudentTotalScores(), isEmpty);
    expect(
      await helper.getStudentTotalScoresByPeriodRange(startPeriod: 1, endPeriod: 1),
      isEmpty,
    );
    expect(
      await helper.getNextStudentNumber(),
      '1',
      reason: '学号 01 被释放后应当能重新分配',
    );
  });

  test('删除评分项：列表里不再出现', () async {
    final ids = await seed();
    await helper.deleteScoreItem(ids['item']!);
    expect(await helper.getScoreItems(), isEmpty);
  });

  test('删除评分记录：明细、分布、总分都不再计入', () async {
    final ids = await seed();
    await helper.deleteScoreRecord(ids['record']!);

    expect(await helper.getScoreRecordsAdvanced(), isEmpty);
    expect(
      await helper.getScoreDistributionByItem(),
      isEmpty,
    );
    final averages = await helper.getAverageDailyScores();
    expect((averages['total_positive'] as num).toDouble(), 0);
  });

  test('删除课程：课表查询不再返回它', () async {
    final id = await helper.insertCourseSchedule({
      'weekday': 1,
      'course_name': '数学',
      'start_time': '08:00',
      'end_time': '08:45',
    });
    await helper.deleteCourseSchedule(id);
    expect(await helper.getCourseSchedules(), isEmpty);
  });
}
