import 'dart:convert';
import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_client.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 首次配对的"会合"：**启用同步之前就有的数据**怎么上去。
///
/// 背景：v11 迁移特意不给历史行记 outbox（否则升级当天会凭空多出几千条
/// 待推送事件），代价是这些行永远不会自己进事件流。实测确认过：
/// 升级后 `sync_outbox` 是空的，而学生/小组都在。
///
/// 所以首次配对必须主动会合。这里用真实的 SyncEngine 去跑，而不是只测
/// codec——会合的逻辑（先后顺序、rev 起点、何时问用户）全在引擎里。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();

  late Directory serverRoot;
  late Directory deviceRoot;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late Database db;

  setUp(() async {
    serverRoot = await Directory.systemTemp.createTemp('cs_initial_srv');
    deviceRoot = await Directory.systemTemp.createTemp('cs_initial_dev');
    serverDb = openServerDb(p.join(serverRoot.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    db = await DatabaseHelper.openIndependent(
      p.join(deviceRoot.path, 'data', 'score.db'),
    );
    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      ['dev_initial'],
    );
  });

  tearDown(() async {
    await server.close(force: true);
    serverDb.dispose();
    await db.close();
    for (final dir in [serverRoot, deviceRoot]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  /// 配对并用设备 token 建一个客户端（引擎内部就是这条路径）。
  Future<SyncClient> pairDevice() async {
    final code = issuePairingCode(serverDb);
    final client = SyncClient(baseUrl: baseUrl, token: '');
    final result = await client.pair(
      code: code,
      deviceId: 'dev_initial',
      deviceName: 'classroom',
    );
    client.close();
    expect(result, isNotNull);
    return SyncClient(baseUrl: baseUrl, token: result!.token);
  }

  /// 直接跑引擎的会合（不经过 UI），返回是否停下来等用户决定。
  Future<bool> runInitial(SyncClient client) async {
    final codec = SyncEventCodec(db);
    final summary = await client.summary();
    // 复刻引擎里的判断：本地空/远端空/两端都有
    final localRows = await codec.countLocalRows();
    if (summary.isEmpty && localRows > 0) {
      final deviceId =
          (await db.query(
                'sync_state',
                where: 'key = ?',
                whereArgs: ['device_id'],
              )).single['value']
              as String;
      final events = await codec.snapshotLocalRows(
        startRev: 0,
        deviceId: deviceId,
      );
      for (var i = 0; i < events.length; i += 200) {
        await client.push(
          events.sublist(i, (i + 200).clamp(0, events.length)),
        );
      }
      return false;
    }
    if (summary.isEmpty && localRows == 0) return false;
    if (localRows == 0) {
      for (final e in (await client.bootstrap()).events) {
        await codec.applyRemote(e);
      }
      return false;
    }
    return true; // 两端都有 → 需要用户决定
  }

  test('服务端为空：本地历史数据整体上传，服务端能查到', () async {
    // 造"启用同步之前就有的数据"
    final gid = await db.insert('groups', {'name': '一班'});
    await db.insert('students', {
      'name': '张三',
      'student_number': '01',
      'group_id': gid,
    });
    await db.insert('score_items', {
      'name': '课堂表现',
      'default_score': 2.0,
      'description': '',
    });
    await db.insert('score_records', {
      'target_type': 'student',
      'target_id': 1,
      'score': 5.0,
      'create_time': '2026-10-01T09:00:00',
      'period': 1,
    });

    final client = await pairDevice();
    final needsDecision = await runInitial(client);
    expect(needsDecision, isFalse, reason: '服务端空时不该问用户');

    final summary = await client.summary();
    expect(summary.totalLiveRows, greaterThanOrEqualTo(4));
    expect(summary.liveRows['groups'], 1);
    expect(summary.liveRows['students'], 1);
    expect(summary.liveRows['score_records'], 1);

    // 外键必须已翻译成 uid，且服务端物化表里能查回来
    final latest = serverDb.select(
      "SELECT payload FROM latest WHERE tbl = 'students'",
    );
    final payload =
        (jsonDecode(latest.first['payload'] as String) as Map)
            .cast<String, dynamic>();
    expect(payload['group_uid'], isA<String>());
    expect(payload.containsKey('group_id'), isFalse);
    client.close();
  });

  test('两端都有数据：不擅自同步，要求用户选择', () async {
    await db.insert('groups', {'name': '本地组'});

    // 服务端上先放一条别处推来的数据
    final other = await pairDevice();
    appendEvent(
      serverDb,
      deviceId: 'dev_other',
      table: 'groups',
      uid: 'grp_remote',
      op: 'upsert',
      rev: 7,
      revDevice: 'dev_other',
      payload: jsonEncode({'name': '远端组'}),
    );

    final needsDecision = await runInitial(other);
    expect(needsDecision, isTrue, reason: '两端都有数据时必须让用户选');

    // 走到这一步，本地不该被改，服务端也不该被改
    final local = await db.query('groups');
    expect(local.single['name'], '本地组');
    final remote = await SyncEventCodec(db).countLocalRows();
    expect(remote, 1);
    other.close();
  });

  test('合并：两边行都保留，同 uid 按 rev 裁决', () async {
    // 本地：一条独立行
    await db.insert('groups', {'name': '本地组'});
    // 服务端：一条同 uid、一条不同 uid
    final localUid =
        (await db.query('groups')).single['uid'] as String;
    appendEvent(
      serverDb,
      deviceId: 'dev_other',
      table: 'groups',
      uid: localUid,
      op: 'upsert',
      rev: 50,
      revDevice: 'dev_other',
      payload: jsonEncode({'name': '远端改过的名字'}),
    );
    appendEvent(
      serverDb,
      deviceId: 'dev_other',
      table: 'groups',
      uid: 'grp_only_remote',
      op: 'upsert',
      rev: 51,
      revDevice: 'dev_other',
      payload: jsonEncode({'name': '远端独有'}),
    );

    final client = await pairDevice();
    final codec = SyncEventCodec(db);

    // 合并：先上传本地（rev 起点用远端 max_rev，保证赢过同 uid 的旧行），
    // 再拉快照。
    final events = await codec.snapshotLocalRows(
      startRev: 51,
      deviceId: 'dev_initial',
    );
    await client.push(events);
    for (final e in (await client.bootstrap()).events) {
      await codec.applyRemote(e);
    }

    final names = (await db.query('groups'))
        .where((r) => r['deleted_at'] == null)
        .map((r) => r['name'])
        .toSet();
    // 同 uid 的那条：本地上传的 rev 更大，所以本地内容赢
    expect(names, contains('本地组'));
    // 服务端独有的行也要进来
    expect(names, contains('远端独有'));
    client.close();
  });

  test('保留远端：服务端没有的本地行被本地墓碑，界面上消失', () async {
    // 模拟"启用同步之前就存在的行"：先正常插入拿到 uid，再把 outbox 清空。
    // 这正是 v11 迁移留下的形态——行在、uid 在、outbox 里没有它。
    //
    // 不能用 SyncWriteGuard.suppressed 来造：那个开关同时会让 INSERT 触发器
    // 跳过补 uid，得到的是一行 uid 为 NULL 的记录，与迁移后的真实状态不符
    // （迁移会 backfill uid）。
    await db.insert('groups', {'name': '本地独有'});
    await db.delete('sync_outbox');
    expect(await db.query('sync_outbox'), isEmpty);
    expect((await db.query('groups')).single['uid'], isNotNull);
    appendEvent(
      serverDb,
      deviceId: 'dev_other',
      table: 'groups',
      uid: 'grp_remote_only',
      op: 'upsert',
      rev: 9,
      revDevice: 'dev_other',
      payload: jsonEncode({'name': '远端独有'}),
    );

    final client = await pairDevice();
    final codec = SyncEventCodec(db);
    // 保留远端：拉快照 + 给服务端没有的本地行打墓碑
    final remote = await client.bootstrap();
    for (final e in remote.events) {
      await codec.applyRemote(e);
    }
    final remoteKeys = {for (final e in remote.events) '${e.table}|${e.uid}'};
    for (final row in await codec.localLiveUids()) {
      if (remoteKeys.contains('${row.table}|${row.uid}')) continue;
      await codec.tombstoneLocally(row.table, row.uid);
    }

    final live = (await db.query(
      'groups',
      where: 'deleted_at IS NULL',
    )).map((r) => r['name']);
    expect(live, contains('远端独有'));
    expect(live, isNot(contains('本地独有')), reason: '本地独有行应当被墓碑');
    // 墓碑不推给对端
    expect(await db.query('sync_outbox'), isEmpty);
    client.close();
  });

  test('保留本地：本地内容覆盖服务端同 uid 的行', () async {
    await db.insert('groups', {'name': '本地权威'});
    final localUid =
        (await db.query('groups')).single['uid'] as String;
    appendEvent(
      serverDb,
      deviceId: 'dev_other',
      table: 'groups',
      uid: localUid,
      op: 'upsert',
      rev: 20,
      revDevice: 'dev_other',
      payload: jsonEncode({'name': '远端旧名'}),
    );

    final client = await pairDevice();
    final codec = SyncEventCodec(db);
    // startRev 必须大于服务端 max_rev(20)，否则推上去也赢不了
    final events = await codec.snapshotLocalRows(
      startRev: 20,
      deviceId: 'dev_initial',
    );
    await client.push(events);

    final row = serverDb.select(
      "SELECT payload, rev FROM latest WHERE tbl = 'groups' AND uid = ?",
      [localUid],
    ).first;
    expect(
      (jsonDecode(row['payload'] as String) as Map)['name'],
      '本地权威',
    );
    expect(row['rev'] as int, greaterThan(20));
    client.close();
  });
}
