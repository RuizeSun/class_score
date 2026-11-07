import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 游标与毒事件的处置。
///
/// 这里的原则是：**宁可重试，不可静默跳过**。一条应用不了的事件如果被游标
/// 越过，它就永远不会再被处理——界面上只表现为"有 N 条事件无法应用"，
/// 而下一轮成功同步就会把这个提示清掉，数据永久缺失且无人知晓。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory root;
  late Database db;
  late SyncEventCodec codec;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_cursor_retry');
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

  test('解码不出来（未知表名）的 outbox 行会被丢弃而不是堵住队列', () async {
    await db.insert('sync_outbox', {
      'tbl': 'unknown_table',
      'uid': 'x1',
      'op': 'upsert',
      'payload': '{"a":1}',
      'rev': 1,
      'rev_device': 'd',
      'created_at': 'now',
    });
    // 后面还有一条正常的
    await db.insert('groups', {'name': '正常'});

    final events = await codec.readOutbox();
    expect(events, hasLength(1), reason: '好的事件仍然要能读出来');
    expect(events.single.table, 'groups');

    final left = await db.query('sync_outbox');
    expect(
      left.where((r) => r['tbl'] == 'unknown_table'),
      isEmpty,
      reason: '坏行必须删掉，否则每轮都重读同一批、永远推不出去',
    );
    expect(SyncEventCodec.droppedOutboxRows, greaterThan(0));
  });

  test('applyRemote 失败时整条回滚，不留半写状态', () async {
    // 先用一条正常事件把 lamport 抬高
    await codec.applyRemote(const SyncEvent(
      table: 'groups',
      uid: 'grp_ok',
      op: SyncOp.upsert,
      rev: 3,
      revDevice: 'devA',
      data: {'name': 'ok'},
    ));
    final before = await db.rawQuery(
      "SELECT value FROM sync_state WHERE key = 'lamport'",
    );

    // course_schedule.weekday 是 NOT NULL，而这条事件的 payload 里没有它 ——
    // 写库必然失败。这条事件会在「抬 lamport 之后、写业务行之前」失败，
    // 正是旧实现会留下"lamport 已抬高、数据没进来"的那个位置。
    await expectLater(
      codec.applyRemote(const SyncEvent(
        table: 'course_schedule',
        uid: 'crs_bad',
        op: SyncOp.upsert,
        rev: 99,
        revDevice: 'devA',
        data: {'course_name': 'x'},
      )),
      throwsA(anything),
    );

    final rows = await db.query('course_schedule');
    expect(rows, isEmpty, reason: '失败的事件必须整条回滚');
    final after = await db.rawQuery(
      "SELECT value FROM sync_state WHERE key = 'lamport'",
    );
    expect(
      after.single['value'],
      before.single['value'],
      reason: 'lamport 不能在写库失败后被抬高（否则本地改不动自己）',
    );
  });

  test('applying 标记在事务失败后仍然复位', () async {
    try {
      await codec.applyRemote(const SyncEvent(
        table: 'score_records',
        uid: 'rec_bad',
        op: SyncOp.upsert,
        rev: 1,
        revDevice: 'devA',
        data: {'score': 'not-a-number'},
      ));
    } catch (_) {
      // 预期
    }
    final applying = await db.rawQuery(
      "SELECT value FROM sync_state WHERE key = 'applying'",
    );
    expect(applying.single['value'], '0', reason: '卡在 1 会让此后所有编辑不同步');
  });

  test('正常事件应用后仍会推进 lamport', () async {
    await codec.applyRemote(const SyncEvent(
      table: 'groups',
      uid: 'grp_x',
      op: SyncOp.upsert,
      rev: 42,
      revDevice: 'devA',
      data: {'name': 'x'},
    ));
    final lamport = await db.rawQuery(
      "SELECT value FROM sync_state WHERE key = 'lamport'",
    );
    expect(int.parse(lamport.single['value'] as String), greaterThanOrEqualTo(42));
  });
}
