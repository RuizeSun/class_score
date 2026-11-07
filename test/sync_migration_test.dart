import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 双库对跑：模拟「大屏」和「另一台机器」两台设备通过服务端收敛。
///
/// 这里不走真实 HTTP，而是直接拿 A 的 outbox 事件喂给 B 的 codec——
/// 测试关注的是**客户端侧的正确性**（uid 翻译、LWW、墓碑、打环）；
/// 端到端 HTTP 由 test/sync_e2e_test.dart 覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory rootA;
  late Directory rootB;
  late Database dbA;
  late Database dbB;

  /// 两台设备必须各自持有**独立连接**（单例只能缓存一个连接）。
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
    rootA = await Directory.systemTemp.createTemp('cs_a');
    rootB = await Directory.systemTemp.createTemp('cs_b');
    dbA = await openAt(rootA, 'devA');
    dbB = await openAt(rootB, 'devB');
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
    DatabaseHelper.instance.closeDatabase();
    if (rootA.existsSync()) rootA.deleteSync(recursive: true);
    if (rootB.existsSync()) rootB.deleteSync(recursive: true);
  });

  test('A 的插入经 outbox 翻译后能在 B 上还原，外键指向正确的行', () async {
    final groupId = await dbA.insert('groups', {'name': '一班'});
    final groupRow =
        (await dbA.query('groups', where: 'id = ?', whereArgs: [groupId])).single;
    await dbA.insert('students', {
      'name': '张三',
      'student_number': '01',
      'group_id': groupId,
    });

    final events = await SyncEventCodec(dbA).readOutbox();
    expect(events, hasLength(2));
    final studentEvent = events.firstWhere((e) => e.table == 'students');
    // 外键必须已翻译成 uid，而不是本地 id
    expect(studentEvent.data!['group_uid'], groupRow['uid']);
    expect(studentEvent.data!.containsKey('group_id'), isFalse);

    final codecB = SyncEventCodec(dbB);
    for (final event in events) {
      await codecB.applyRemote(event);
    }
    final students = await dbB.query('students');
    expect(students, hasLength(1));
    expect(students.single['name'], '张三');
    final groupsOnB = await dbB.query('groups');
    expect(groupsOnB, hasLength(1));
    expect(students.single['group_id'], groupsOnB.single['id']);
    expect(groupsOnB.single['name'], '一班');
  });

  test('应用远端事件不产生新的 outbox（打环保险）', () async {
    await dbA.insert('groups', {'name': '一班'});
    final events = await SyncEventCodec(dbA).readOutbox();
    await SyncEventCodec(dbB).applyRemote(events.single);
    final outboxOnB = await dbB.query('sync_outbox');
    expect(outboxOnB, isEmpty, reason: 'B 应用远端事件后不该再推回给 A');
  });

  test('LWW：rev 大者胜，旧事件回放不会覆盖新值', () async {
    final codecA = SyncEventCodec(dbA);
    final codecB = SyncEventCodec(dbB);

    final idA = await dbA.insert('groups', {'name': '旧名'});
    await dbA.update(
      'groups',
      {'name': '新名'},
      where: 'id = ?',
      whereArgs: [idA],
    );
    final events = await codecA.readOutbox();
    expect(events, hasLength(2));

    for (final e in events) {
      await codecB.applyRemote(e);
    }
    expect((await dbB.query('groups')).single['name'], '新名');

    // 回放更旧的那条：不该覆盖
    await codecB.applyRemote(events.first);
    expect((await dbB.query('groups')).single['name'], '新名');
  });

  test('删除变墓碑：一端删除，另一端跟着消失但行仍在', () async {
    final idA = await dbA.insert('groups', {'name': '要删的组'});
    await dbA.delete('groups', where: 'id = ?', whereArgs: [idA]);

    final rowsA = await dbA.query('groups');
    expect(rowsA, hasLength(1), reason: '物理删除被 RAISE(IGNORE) 拦住了');
    expect(rowsA.single['deleted_at'], isNotNull);

    for (final e in await SyncEventCodec(dbA).readOutbox()) {
      await SyncEventCodec(dbB).applyRemote(e);
    }
    final rowsB = await dbB.query('groups');
    expect(rowsB.single['deleted_at'], isNotNull);
  });

  test('lamport 抬到远端 rev，本地后续写入仍然能赢', () async {
    await SyncEventCodec(dbB).applyRemote(
      const SyncEvent(
        table: 'groups',
        uid: 'grp_remote',
        op: SyncOp.upsert,
        rev: 100,
        revDevice: 'devA',
        data: {'name': '远端'},
      ),
    );
    final lamportRow = await dbB.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: ['lamport'],
    );
    expect(int.parse(lamportRow.single['value'] as String), greaterThanOrEqualTo(100));

    final id = await dbB.insert('groups', {'name': '本地'});
    await dbB.update(
      'groups',
      {'name': '本地2'},
      where: 'id = ?',
      whereArgs: [id],
    );
    final row =
        (await dbB.query('groups', where: 'id = ?', whereArgs: [id])).single;
    expect(row['rev'], greaterThan(100));
  });

  test('父行未到就先收到子行：占位行不破坏外键，父行到达后补全', () async {
    // 手工造一条"学生先到、小组后到"的事件
    final codecB = SyncEventCodec(dbB);
    await codecB.applyRemote(
      const SyncEvent(
        table: 'students',
        uid: 'stu_early',
        op: SyncOp.upsert,
        rev: 10,
        revDevice: 'devA',
        data: {
          'name': '早到的学生',
          'student_number': '09',
          'group_uid': 'grp_late',
          'include_in_group_total': 1,
        },
      ),
    );
    // 小组此时并不存在，学生指向一个占位小组
    var groups = await dbB.query('groups');
    expect(groups, hasLength(1));
    expect(groups.single['uid'], 'grp_late');

    await codecB.applyRemote(
      const SyncEvent(
        table: 'groups',
        uid: 'grp_late',
        op: SyncOp.upsert,
        rev: 11,
        revDevice: 'devA',
        data: {'name': '后到的小组'},
      ),
    );
    groups = await dbB.query('groups');
    expect(groups, hasLength(1), reason: '占位行应被同 uid 的真实事件覆盖，而不是新增一行');
    expect(groups.single['name'], '后到的小组');
  });
}
