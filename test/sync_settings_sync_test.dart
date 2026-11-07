import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 计分规则与当前周期必须同步；本机外观绝不能同步。
///
/// 前者决定"同一个班在两台机器上算出多少分"，不同步的话老师端看到的分数
/// 永远和大屏对不上。后者（主题色、悬浮课表位置、天气城市）跟着跑只会在
/// 两台不同尺寸的机器上互相打架。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory a;
  late Directory b;
  late Database dbA;
  late Database dbB;

  Future<Database> openAt(Directory root, String deviceId) async {
    final db = await DatabaseHelper.openIndependent(
      p.join(root.path, 'data', 'score.db'),
    );
    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      [deviceId],
    );
    return db;
  }

  setUp(() async {
    a = await Directory.systemTemp.createTemp('cs_set_a');
    b = await Directory.systemTemp.createTemp('cs_set_b');
    dbA = await openAt(a, 'devA');
    dbB = await openAt(b, 'devB');
    // 触发器只对白名单记账，先把白名单之外的也各写几条
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
    for (final dir in [a, b]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  Future<void> merge() async {
    for (final e in await SyncEventCodec(dbA).readOutbox()) {
      await SyncEventCodec(dbB).applyRemote(e);
    }
    for (final e in await SyncEventCodec(dbB).readOutbox()) {
      await SyncEventCodec(dbA).applyRemote(e);
    }
  }

  /// 写一个设置项。
  ///
  /// 刻意**不用** `ConflictAlgorithm.replace`：那在 SQLite 里是"先删后插"，
  /// 而 v11 起删除会变墓碑 + 拿到全新 uid，等于"这一行被换成了另一个对象"。
  /// 这正是 DatabaseHelper.setSetting 曾经踩过的坑。
  Future<void> set(Database db, String key, String value) async {
    final updated = await db.update(
      'app_settings',
      {'value': value, 'deleted_at': null},
      where: 'key = ?',
      whereArgs: [key],
    );
    if (updated > 0) return;
    await db.insert('app_settings', {'key': key, 'value': value});
  }

  test('切换周期会同步', () async {
    await set(dbA, 'current_period', '1');
    await merge();
    await set(dbA, 'current_period', '2');
    await merge();

    final onB = await dbB.query(
      'app_settings',
      where: 'key = ? AND deleted_at IS NULL',
      whereArgs: ['current_period'],
    );
    expect(onB.single['value'], '2', reason: '老师端必须跟着切到第 2 周期');
  });

  test('计分规则会同步：改初始分与小组算法', () async {
    await set(dbA, 'student_initial_score', '5');
    await set(dbA, 'group_initial_score', '10');
    await set(dbA, 'group_score_mode', 'average');
    await merge();

    Future<String?> readOnB(String key) async {
      final rows = await dbB.query(
        'app_settings',
        where: 'key = ? AND deleted_at IS NULL',
        whereArgs: [key],
      );
      return rows.isEmpty ? null : rows.single['value'] as String?;
    }

    expect(await readOnB('student_initial_score'), '5');
    expect(await readOnB('group_initial_score'), '10');
    expect(await readOnB('group_score_mode'), 'average');
  });

  test('本机外观不同步：主题色、悬浮课表、天气城市', () async {
    for (final key in [
      'theme_seed_color',
      'desktop_bar_position',
      'desktop_ball_offset_x',
      'weather_city',
      'close_to_tray',
      'analysis_split_ratio',
    ]) {
      await set(dbA, key, 'some-value');
    }
    final outbox = await dbA.query('sync_outbox');
    expect(
      outbox,
      isEmpty,
      reason: '外观与本机行为绝不能进同步队列',
    );
    await merge();
    final onB = await dbB.query('app_settings');
    expect(
      onB.where((r) => r['key'] != 'current_period'),
      isEmpty,
      reason: '外观键不该出现在对端（current_period 是迁移自带的默认值，不算）',
    );
  });

  test('安全相关不同步：pin_hash', () async {
    await set(dbA, 'pin_hash', 'deadbeef');
    expect(await dbA.query('sync_outbox'), isEmpty);
    await merge();
    final pinOnB = await dbB.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['pin_hash'],
    );
    expect(pinOnB, isEmpty, reason: '解锁凭据绝不能离开本机');
  });

  test('两端都改同一个键：按 rev 裁决，不产生第二行', () async {
    await set(dbA, 'current_period', '1');
    await merge();

    // 两端各自改
    await set(dbA, 'current_period', '2');
    await set(dbB, 'current_period', '3');
    await merge();

    for (final db in [dbA, dbB]) {
      final rows = await db.query(
        'app_settings',
        where: 'key = ? AND deleted_at IS NULL',
        whereArgs: ['current_period'],
      );
      expect(rows, hasLength(1), reason: 'key 是主键，绝不能出现两条');
    }
    final onA = (await dbA.query('app_settings',
        where: 'key = ? AND deleted_at IS NULL',
        whereArgs: ['current_period'])).single['value'];
    final onB = (await dbB.query('app_settings',
        where: 'key = ? AND deleted_at IS NULL',
        whereArgs: ['current_period'])).single['value'];
    expect(onA, onB, reason: '两端必须收敛到同一个值');
  });

  test('应用远端设置不会回推（打环保险）', () async {
    await set(dbA, 'current_period', '4');
    for (final e in await SyncEventCodec(dbA).readOutbox()) {
      await SyncEventCodec(dbB).applyRemote(e);
    }
    expect(await dbB.query('sync_outbox'), isEmpty);
  });
}
