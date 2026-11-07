import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/database/sync_write_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `suppressed`（导入/重置/恢复备份）之后，行必须拿到 uid。
///
/// 背景：suppressed 期间 INSERT 触发器被 `WHEN applying = '0'` 关掉，
/// 新行拿到的是 **NULL uid**。而 AFTER UPDATE 触发器会
/// `INSERT INTO sync_outbox ... SELECT r.uid`，uid 为 NULL 直接撞
/// `sync_outbox.uid NOT NULL`。
///
/// 实测后果：恢复备份之后，老师改任何一个名字都会抛
/// `NOT NULL constraint failed: sync_outbox.uid` ——
/// 因为大多数 Provider 把这个异常吞掉，界面上表现为"点了没反应"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory root;
  late Database db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_uid_backfill');
    db = await DatabaseHelper.openIndependent(
      p.join(root.path, 'data', 'score.db'),
    );
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 复刻 backup_service.importFromJson 的写法：整库覆盖 + 重新插入。
  Future<void> importLike() async {
    await SyncWriteGuard.suppressed(db, () async {
      await db.delete('score_records');
      await db.delete('students');
      await db.delete('groups');
      await db.insert('groups', {'name': '一班'});
      await db.insert('groups', {'name': '二班'});
    });
  }

  test('suppressed 导入后每行都有 uid', () async {
    await importLike();
    final groups = await db.query('groups');
    expect(groups, hasLength(2));
    for (final row in groups) {
      expect(row['uid'], isNotNull, reason: '缺 uid 的行以后一定会炸');
      expect(row['uid'], isNotEmpty);
    }
  });

  test('导入后立刻改名不再抛 NOT NULL', () async {
    await importLike();
    final groups = await db.query('groups');
    // 这正是老师最常做的下一步操作
    await db.update(
      'groups',
      {'name': '一班（改）'},
      where: 'id = ?',
      whereArgs: [groups.first['id']],
    );
    final outbox = await db.query('sync_outbox');
    expect(outbox, hasLength(1), reason: '改名应当正常记一条事件');
    expect(outbox.single['uid'], groups.first['uid']);
  });

  test('导入后新建/删除也正常', () async {
    await importLike();
    final id = await db.insert('groups', {'name': '三班'});
    await db.delete('groups', where: 'id = ?', whereArgs: [id]);
    expect(await db.query('sync_outbox'), hasLength(2));
  });

  test('suppressed 结束一定把 applying 复位', () async {
    await importLike();
    final rows = await db.rawQuery(
      "SELECT value FROM sync_state WHERE key = 'applying'",
    );
    expect(rows.single['value'], '0');
  });

  test('补 uid 不碰白名单外的设置（pin_hash 仍然没有 uid）', () async {
    await db.insert('app_settings', {'key': 'pin_hash', 'value': 'SECRET'});
    // 再跑一次整库级写入，backfill 会覆盖所有表
    await SyncWriteGuard.suppressed(db, () async {
      await db.insert('groups', {'name': 'x'});
    });
    final pin = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['pin_hash'],
    );
    expect(
      pin.single['uid'],
      isNull,
      reason: '没 uid 的行会被快照跳过，这是凭据不外泄的第二道保险',
    );
    // 白名单内的键仍然会被补
    final period = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['current_period'],
    );
    expect(period.single['uid'], isNotNull);
  });
}
