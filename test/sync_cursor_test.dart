import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_client.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 游标推进规则：**只有 pull 才能推进 server_seq**。
///
/// 这是一个真实会丢数据的问题：push 的应答里带的 seq 是服务端**全局**最大
/// 序号，而不是"我推的这批"。如果拿它当拉取游标，别人在这之前推的事件就
/// 被永久跳过了——而两端的界面看起来都正常，只是少了几条记录。
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
    root = await Directory.systemTemp.createTemp('cs_cursor_srv');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    rootA = await Directory.systemTemp.createTemp('cs_cursor_a');
    rootB = await Directory.systemTemp.createTemp('cs_cursor_b');
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

  test('B 先推、A 后推：A 拉取时必须仍然看得到 B 的那条', () async {
    final clientA = await pairAs('devA');
    final clientB = await pairAs('devB');

    await dbB.insert('groups', {'name': 'B 建的组'});
    await clientB.push(await SyncEventCodec(dbB).readOutbox());

    await dbA.insert('groups', {'name': 'A 建的组'});
    final responseA = await clientA.push(await SyncEventCodec(dbA).readOutbox());
    expect(responseA.accepted, 1);

    final page = await clientA.pull(since: 0);
    expect(
      page.events.map((e) => e.data!['name']),
      contains('B 建的组'),
      reason: 'push 的应答 seq 是全局最大序号，不能拿来当拉取游标',
    );

    clientA.close();
    clientB.close();
  });

  test('引擎行为复现：push 之后把应答 seq 写进游标，再拉取会漏掉别人的事件', () async {
    final clientA = await pairAs('devA');
    final clientB = await pairAs('devB');

    await dbB.insert('groups', {'name': 'B 建的组'});
    await clientB.push(await SyncEventCodec(dbB).readOutbox());

    await dbA.insert('groups', {'name': 'A 建的组'});
    final pushResponse =
        await clientA.push(await SyncEventCodec(dbA).readOutbox());

    // 复刻 SyncEngine._push 的行为：把 push 应答里的 seq 当成游标存下来
    final cursor = pushResponse.seq;
    final page = await clientA.pull(since: cursor);

    expect(
      page.events.where((e) => e.data?['name'] == 'B 建的组'),
      isEmpty,
      reason: '这就是缺陷本身：push 应答的 seq 已经越过了 B 的事件',
    );

    clientA.close();
    clientB.close();
  });
}
