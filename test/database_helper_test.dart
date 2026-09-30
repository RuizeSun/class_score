import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 覆盖仪表盘依赖的 `getScoreRecords` 过滤能力：日期范围下推到 SQL、LIMIT 取前 N 条。
///
/// 仪表盘以前是「读整个周期的记录 → 在 Dart 里过滤今天」，同一份记录还查两遍；
/// 现在改成一条带日期范围的查询 + 一条带 LIMIT 的查询，这里守住这两条 SQL 的语义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory root;
  late Database db;

  const today = '2026-09-30';
  const yesterday = '2026-09-29';

  Future<int> insertRecord({
    required String createTime,
    int period = 1,
    String targetType = 'student',
  }) => db.insert('score_records', {
    'target_type': targetType,
    'target_id': 1,
    'score': 1,
    'reason': '',
    'create_time': createTime,
    'period': period,
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('class_score_db');
    DatabaseHelper.dbDirOverride = p.join(root.path, 'data');
    db = await DatabaseHelper.instance.database;
  });

  tearDown(() async {
    await DatabaseHelper.instance.closeDatabase();
    DatabaseHelper.dbDirOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('不带新参数时行为不变：返回该周期全部记录（按时间倒序）', () async {
    await insertRecord(createTime: '${yesterday}T08:00:00.000');
    await insertRecord(createTime: '${today}T09:00:00.000');
    await insertRecord(createTime: '${today}T08:00:00.000');

    final rows = await DatabaseHelper.instance.getScoreRecords(period: 1);
    expect(rows.map((r) => r['create_time']).toList(), [
      '${today}T09:00:00.000',
      '${today}T08:00:00.000',
      '${yesterday}T08:00:00.000',
    ]);
  });

  test('startDate / endDate 把「只要今天」的过滤下推到 SQL', () async {
    await insertRecord(createTime: '${yesterday}T23:59:59.000');
    await insertRecord(createTime: '${today}T08:00:00.000');
    await insertRecord(createTime: '${today}T23:30:00.000');
    // 另一个周期的今日记录：不该被带出来
    await insertRecord(createTime: '${today}T10:00:00.000', period: 2);

    final rows = await DatabaseHelper.instance.getScoreRecords(
      period: 1,
      startDate: '${today}T00:00:00.000',
      endDate: '2026-10-01T00:00:00.000',
    );
    expect(rows.map((r) => r['create_time']).toList(), [
      '${today}T23:30:00.000',
      '${today}T08:00:00.000',
    ]);
  });

  test('limit 只取最新的 N 条（最近评分卡片用）', () async {
    await insertRecord(createTime: '${yesterday}T08:00:00.000');
    await insertRecord(createTime: '${today}T08:00:00.000');
    await insertRecord(createTime: '${today}T09:00:00.000');

    final rows = await DatabaseHelper.instance.getScoreRecords(
      period: 1,
      limit: 2,
    );
    expect(rows.map((r) => r['create_time']).toList(), [
      '${today}T09:00:00.000',
      '${today}T08:00:00.000',
    ]);
  });
}
