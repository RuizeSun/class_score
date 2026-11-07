import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_client.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 全量对齐（/sync/bootstrap）：本地库丢了同步元数据/游标之后，
/// 靠服务端快照把内容整体铺回来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();

  late Directory root;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late Directory rootA;
  late Directory rootC;
  late Database dbA;
  late Database dbC;

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
    root = await Directory.systemTemp.createTemp('cs_boot_srv');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    rootA = await Directory.systemTemp.createTemp('cs_boot_a');
    rootC = await Directory.systemTemp.createTemp('cs_boot_c');
    dbA = await openAt(rootA, 'devA');
    dbC = await openAt(rootC, 'devC');
  });

  tearDown(() async {
    await server.close(force: true);
    serverDb.dispose();
    await dbA.close();
    await dbC.close();
    for (final dir in [root, rootA, rootC]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('新设备用全量对齐直接拿到当前值，不需要回放事件历史', () async {
    final clientA = await pairAs('devA');
    final clientC = await pairAs('devC');

    // A 建数据并改名两次：服务端只该记住最后一版
    final groupId = await dbA.insert('groups', {'name': '旧名'});
    await dbA.update(
      'groups',
      {'name': '新名'},
      where: 'id = ?',
      whereArgs: [groupId],
    );
    await clientA.push(await SyncEventCodec(dbA).readOutbox());

    final page = await clientC.bootstrap();
    expect(
      page.events,
      hasLength(1),
      reason: '快照只回每行最新状态，不回 3 条历史事件',
    );
    expect(page.events.single.data!['name'], '新名');

    final codecC = SyncEventCodec(dbC);
    for (final event in page.events) {
      await codecC.applyRemote(event);
    }
    expect((await dbC.query('groups')).single['name'], '新名');

    clientA.close();
    clientC.close();
  });

  test('全量对齐后本地不会因为"应用远端事件"而回推（打环保险仍然有效）', () async {
    final clientA = await pairAs('devA');
    final clientC = await pairAs('devC');

    await dbA.insert('groups', {'name': '一班'});
    await clientA.push(await SyncEventCodec(dbA).readOutbox());

    final codecC = SyncEventCodec(dbC);
    for (final event in (await clientC.bootstrap()).events) {
      await codecC.applyRemote(event);
    }
    expect(await dbC.query('sync_outbox'), isEmpty);

    clientA.close();
    clientC.close();
  });
}
