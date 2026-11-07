import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_client.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_server/sync_server.dart';
import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 一条坏事件不能把整条同步链路卡死。
///
/// 场景：服务端上存在一条本地无法应用的事件（比如来自更新版本的客户端，
/// target_type 是本机不认识的值）。如果 applyRemote 抛出后游标不前进，
/// 那么**每一轮拉取都会重新拿到同一条事件**、每次都抛、每次都卡在这里，
/// 后面所有设备的所有改动都永远进不来——而界面上只是"同步不动了"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();

  late Directory root;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late Directory rootA;
  late Directory rootB;
  late Database dbA;
  late Database dbB;

  Future<Database> openAt(Directory dir, String deviceId) async {
    final db = await DatabaseHelper.openIndependent(
      p.join(dir.path, 'data', 'score.db'),
    );
    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      [deviceId],
    );
    return db;
  }

  Future<SyncClient> pairAs(String deviceId) async {
    final code = issuePairingCode(serverDb);
    final client = SyncClient(baseUrl: baseUrl, token: '');
    final result = await client.pair(
      code: code,
      deviceId: deviceId,
      deviceName: deviceId,
    );
    client.close();
    return SyncClient(baseUrl: baseUrl, token: result!.token);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_bad_srv');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    rootA = await Directory.systemTemp.createTemp('cs_bad_a');
    rootB = await Directory.systemTemp.createTemp('cs_bad_b');
    dbA = await openAt(rootA, 'devA');
    dbB = await openAt(rootB, 'devB');
  });

  tearDown(() async {
    await server.close(force: true);
    serverDb.dispose();
    await dbA.close();
    await dbB.close();
    for (final dir in [root, rootA, rootB]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('坏事件被跳过后，同一页里后面的事件仍然能应用', () async {
    final clientA = await pairAs('devA');
    final clientB = await pairAs('devB');

    // A 推一条正常的小组事件
    await dbA.insert('groups', {'name': '一班'});
    await clientA.push(await SyncEventCodec(dbA).readOutbox());

    // 服务端上再塞一条 B 无法应用的事件（模拟"别的版本的客户端"）
    serverDb.execute(
      'INSERT INTO events(device_id, tbl, uid, op, rev, rev_device, payload, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'dev_future',
        'score_records',
        'rec_future',
        'upsert',
        99,
        'dev_future',
        '{"target_type":"hologram","target_uid":"x","score":1,'
            '"create_time":"2026-01-01T00:00:00","period":1}',
        DateTime.now().toIso8601String(),
      ],
    );
    // 再塞一条正常的、排在其后的小组事件
    serverDb.execute(
      'INSERT INTO events(device_id, tbl, uid, op, rev, rev_device, payload, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'dev_other',
        'groups',
        'grp_after',
        'upsert',
        50,
        'dev_other',
        '{"name":"后面的组"}',
        DateTime.now().toIso8601String(),
      ],
    );

    final codecB = SyncEventCodec(dbB);
    final page = await clientB.pull(since: 0);
    final rejected = <String>[];
    for (final event in page.events) {
      try {
        await codecB.applyRemote(event);
      } catch (error) {
        rejected.add('${event.uid}: $error');
      }
    }
    expect(rejected, isEmpty, reason: '坏事件本身也不该抛出：$rejected');

    expect(page.events, hasLength(3));
    // 关键：即使中间那条应用失败，后面的也必须进来
    final groups = await dbB.query('groups');
    expect(
      groups.map((g) => g['name']),
      containsAll(['一班', '后面的组']),
      reason: '一条坏事件不能挡住它后面的事件',
    );

    clientA.close();
    clientB.close();
  });

  test('score_records 的 NOT NULL 外键：坏事件本身也不该抛异常', () async {
    final codecB = SyncEventCodec(dbB);
    await codecB.applyRemote(
      const SyncEvent(
        table: 'score_records',
        uid: 'rec_bad',
        op: SyncOp.upsert,
        rev: 7,
        revDevice: 'devX',
        data: {
          'target_type': 'group',
          'target_uid': '', // 指向一个不存在的空 uid
          'score': 3,
          'create_time': '2026-01-01T00:00:00',
          'period': 1,
        },
      ),
    );
    final record = (await dbB.query('score_records')).single;
    expect(record['score'], 3.0);
  });
}
