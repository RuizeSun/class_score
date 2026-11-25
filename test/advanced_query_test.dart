import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/providers/score_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 高级查询的小组口径：
/// 1) 默认只累计参与小组量化评分的成员；
/// 2) 打开开关后把「不参与小组量化评分」的学生也按普通成员计入；
/// 3) 空的「未分组」不在小组结果里出现，有成员时才出现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory root;
  late Database db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('class_score_advanced');
    DatabaseHelper.dbDirOverride = p.join(root.path, 'data');
    db = await DatabaseHelper.instance.database;

    await DatabaseHelper.instance.setSetting('group_score_mode', 'sum');
    await DatabaseHelper.instance.setSetting('student_initial_score', '0');
    await DatabaseHelper.instance.setSetting('group_initial_score', '0');

    final g1 = await db.insert('groups', {'name': '第一组'});
    final g2 = await db.insert('groups', {'name': '第二组'});
    await db.insert('groups', {'name': '未分组'});

    Future<int> student(String name, int groupId, int includeInGroup) =>
        db.insert('students', {
          'name': name,
          'student_number': name,
          'group_id': groupId,
          'include_in_group_total': includeInGroup,
        });

    final a = await student('A', g1, 1);
    final b = await student('B', g1, 0); // 不参与小组量化评分
    final c = await student('C', g2, 0); // 整组都不参与

    Future<void> rec(int targetId, double score) => db.insert(
      'score_records',
      {
        'target_type': 'student',
        'target_id': targetId,
        'score': score,
        'reason': '',
        'create_time': '2026-01-05T08:00:00.000',
        'period': 1,
      },
    );

    await rec(a, 5);
    await rec(b, 10);
    await rec(c, 7);
  });

  tearDown(() async {
    await DatabaseHelper.instance.closeDatabase();
    DatabaseHelper.dbDirOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<List<Map<String, dynamic>>> runGroupQuery({
    required bool countExcluded,
  }) async {
    final provider = ScoreProvider();
    provider.setAdvancedPeriodRange(1, 1);
    provider.setAdvancedShowGroup(true);
    provider.setAdvancedCountExcludedStudents(countExcluded);
    await provider.executeAdvancedQuery();
    return provider.advancedResults;
  }

  test('默认口径只累计参与小组量化评分的成员', () async {
    final rows = await runGroupQuery(countExcluded: false);
    double scoreOf(String name) => (rows.firstWhere(
          (r) => r['name'] == name,
        )['total_score'] as num)
        .toDouble();

    expect(scoreOf('第一组'), 5); // 只有 A
    expect(scoreOf('第二组'), 0); // C 不参与
  });

  test('打开开关后未参与小组量化评分的学生也计入', () async {
    final rows = await runGroupQuery(countExcluded: true);
    double scoreOf(String name) => (rows.firstWhere(
          (r) => r['name'] == name,
        )['total_score'] as num)
        .toDouble();

    expect(scoreOf('第一组'), 15); // A 5 + B 10
    expect(scoreOf('第二组'), 7); // C 7
  });

  test('空的「未分组」不出现在小组查询结果里', () async {
    final rows = await runGroupQuery(countExcluded: false);
    expect(rows.any((r) => r['name'] == '未分组'), isFalse);
  });

  test('「未分组」有成员时正常出现', () async {
    final ungroupedId = (await db.query(
      'groups',
      where: 'name = ?',
      whereArgs: ['未分组'],
    )).first['id'] as int;
    final d = await db.insert('students', {
      'name': 'D',
      'student_number': 'D',
      'group_id': ungroupedId,
      'include_in_group_total': 1,
    });
    await db.insert('score_records', {
      'target_type': 'student',
      'target_id': d,
      'score': 4,
      'reason': '',
      'create_time': '2026-01-05T08:00:00.000',
      'period': 1,
    });

    final rows = await runGroupQuery(countExcluded: false);
    final ungrouped = rows.firstWhere((r) => r['name'] == '未分组');
    expect((ungrouped['total_score'] as num).toDouble(), 4);
  });
}
