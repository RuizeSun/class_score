import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// 调休：同一天改一次星期，或者删了之后再加回来。
///
/// v11 之前 upsertScheduleAdjustment 是"先 DELETE 再 INSERT"。改造后 DELETE 变成
/// 墓碑（行还在、date 的唯一索引还占着），于是后面的 INSERT 直接撞唯一索引——
/// 老师在界面上"改调休"，什么反应都没有（异常被 Provider 层吞掉）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late DatabaseHelper helper;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_adj');
    DatabaseHelper.dbDirOverride = root.path;
    helper = DatabaseHelper.instance;
  });

  tearDown(() async {
    await helper.closeDatabase();
    DatabaseHelper.dbDirOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('同一天改调休：第二次设置必须覆盖第一次', () async {
    await helper.upsertScheduleAdjustment({
      'date': '2026-11-05',
      'weekday': 3,
      'created_at': DateTime.now().toIso8601String(),
    });
    await helper.upsertScheduleAdjustment({
      'date': '2026-11-05',
      'weekday': 5,
      'created_at': DateTime.now().toIso8601String(),
    });

    final rows = await helper.getScheduleAdjustments();
    expect(rows, hasLength(1));
    expect(rows.single['weekday'], 5, reason: '应当覆盖成新的星期');
  });

  test('删掉调休后可以再设回来', () async {
    await helper.upsertScheduleAdjustment({
      'date': '2026-11-06',
      'weekday': 2,
      'created_at': DateTime.now().toIso8601String(),
    });
    await helper.deleteScheduleAdjustment('2026-11-06');
    expect(await helper.getScheduleAdjustments(), isEmpty);

    await helper.upsertScheduleAdjustment({
      'date': '2026-11-06',
      'weekday': 4,
      'created_at': DateTime.now().toIso8601String(),
    });
    final rows = await helper.getScheduleAdjustments();
    expect(rows, hasLength(1), reason: '墓碑不该挡住重新设置');
    expect(rows.single['weekday'], 4);
  });
}
