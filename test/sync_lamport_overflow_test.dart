import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_engine.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// lamport 的 int64 悬崖。
///
/// lamport 以字符串存在 `sync_state` 里，触发器取号走
/// `CAST(value AS INTEGER) + 1`。一旦它超过 int64（例如被一条恶意远端事件
/// 抬上去），SQLite 会退化成 REAL 并存成浮点字符串 —— 本地时钟从此损坏，
/// 每次取号都得到同一个浮点数，所有本地写入在 LWW 里永久输。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory root;
  late Database db;
  late SyncEventCodec codec;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_lamport');
    db = await DatabaseHelper.openIndependent(
      p.join(root.path, 'data', 'score.db'),
    );
    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      ['devB'],
    );
    codec = SyncEventCodec(db);
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<Object?> lamport() async =>
      (await db.rawQuery("SELECT value FROM sync_state WHERE key = 'lamport'"))
          .single['value'];

  test('应用远端超大 rev 后，lamport 被钳制在 maxSafeRev 且仍是整数', () async {
    await codec.applyRemote(const SyncEvent(
      table: 'groups',
      uid: 'grp_huge',
      op: SyncOp.upsert,
      rev: 9223372036854775807, // int64 上限
      revDevice: 'devA',
      data: {'name': '毒'},
    ));

    final value = await lamport();
    expect(
      int.tryParse('$value'),
      maxSafeRev,
      reason: '钳制在 2^53，给触发器的 +1 留出空间',
    );
  });

  test('钳制后的本地写入仍然能拿到比远端更大的号（整数，非浮点）', () async {
    await codec.applyRemote(const SyncEvent(
      table: 'groups',
      uid: 'grp_huge',
      op: SyncOp.upsert,
      rev: 9223372036854775807,
      revDevice: 'devA',
      data: {'name': '毒'},
    ));

    // 本地再写一次：触发器取号。lamport 必须仍是整数形态。
    await db.insert('groups', {'name': '本地新组'});
    final row = await db.query(
      'groups',
      where: "uid LIKE 'grp_%' AND name = '本地新组'",
    );
    expect(row, hasLength(1));
    expect(row.single['rev'], isA<int>(), reason: '取号结果必须是整数');
    expect(
      int.parse('$row'.isEmpty ? '0' : row.single['rev'].toString()),
      greaterThanOrEqualTo(maxSafeRev),
    );

    final value = await lamport();
    expect(
      int.tryParse('$value'),
      isNotNull,
      reason: 'lamport 不能退化成浮点字符串',
    );
  });

  test('已被污染的浮点 lamport 在 configure() 时自愈', () async {
    // 模拟旧版本留下的损坏状态
    await db.execute(
      "UPDATE sync_state SET value = '9.22337203685478e+18' "
      "WHERE key = 'lamport'",
    );
    expect(int.tryParse('${await lamport()}'), isNull);

    DatabaseHelper.dbDirOverride = p.join(root.path, 'data');
    addTearDown(() => DatabaseHelper.dbDirOverride = null);
    await SyncEngine.instance.configure();

    expect(
      int.tryParse('${await lamport()}'),
      maxSafeRev,
      reason: '启动时把非整数 lamport 归位',
    );
  });

  test('正常范围的远端事件照常抬 lamport（不误伤）', () async {
    await codec.applyRemote(const SyncEvent(
      table: 'groups',
      uid: 'grp_ok',
      op: SyncOp.upsert,
      rev: 42,
      revDevice: 'devA',
      data: {'name': '正常'},
    ));
    expect(int.tryParse('${await lamport()}'), 42);
  });
}
