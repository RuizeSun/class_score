import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// 保存课表不应该"整张换掉"。
///
/// v11 之后删除变墓碑，如果 replaceAllCourseSchedules 仍然是"全删再全插"，
/// 每次保存都会把整张课表换成一批全新 uid 的行——对端看到"整个课表被删掉
/// 又重建"，几十条墓碑事件白白传播，并发的改动也会变成不可解释的冲突。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late DatabaseHelper helper;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_course');
    DatabaseHelper.dbDirOverride = root.path;
    helper = DatabaseHelper.instance;
  });

  tearDown(() async {
    await helper.closeDatabase();
    DatabaseHelper.dbDirOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Map<String, dynamic> course(String name, String start, String end,
          {int weekday = 1}) =>
      {
        'weekday': weekday,
        'course_name': name,
        'start_time': start,
        'end_time': end,
      };

  test('内容没变时保存：不产生任何同步事件', () async {
    await helper.replaceAllCourseSchedules([
      course('数学', '08:00', '08:45'),
      course('语文', '09:00', '09:45'),
    ]);
    final db = await helper.database;
    await db.delete('sync_outbox', where: '1 = 1');

    // 原样再保存一次
    await helper.replaceAllCourseSchedules([
      course('数学', '08:00', '08:45'),
      course('语文', '09:00', '09:45'),
    ]);

    expect(
      await db.query('sync_outbox'),
      isEmpty,
      reason: '内容没变就不该有任何事件',
    );
  });

  test('只删一门课：只产生一条墓碑，未变的课 uid 保持不变', () async {
    await helper.replaceAllCourseSchedules([
      course('数学', '08:00', '08:45'),
      course('语文', '09:00', '09:45'),
    ]);
    final db = await helper.database;
    final before = await db.query('course_schedule', where: 'deleted_at IS NULL');
    final mathUid = before.firstWhere((r) => r['course_name'] == '数学')['uid'];
    await db.delete('sync_outbox', where: '1 = 1');

    await helper.replaceAllCourseSchedules([
      course('数学', '08:00', '08:45'), // 保留
    ]);

    final outbox = await db.query('sync_outbox');
    expect(outbox, hasLength(1), reason: '只该有一条删除事件');
    expect(outbox.single['op'], 'delete');

    final after = await db.query('course_schedule', where: 'deleted_at IS NULL');
    expect(after, hasLength(1));
    expect(
      after.single['uid'],
      mathUid,
      reason: '没变的课必须保住 uid，否则对端看到的是删掉重建',
    );
  });

  test('新增一门课：只产生一条新增事件', () async {
    await helper.replaceAllCourseSchedules([course('数学', '08:00', '08:45')]);
    final db = await helper.database;
    await db.delete('sync_outbox', where: '1 = 1');

    await helper.replaceAllCourseSchedules([
      course('数学', '08:00', '08:45'),
      course('英语', '10:00', '10:45'),
    ]);

    final outbox = await db.query('sync_outbox');
    expect(outbox, hasLength(1));
    expect(outbox.single['op'], 'upsert');
    expect(
      (await db.query('course_schedule', where: 'deleted_at IS NULL')),
      hasLength(2),
    );
  });
}
