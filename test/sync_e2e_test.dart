import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_client.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 端到端：真的把服务端起起来，走 HTTP 配对 / 推送 / 拉取。
///
/// 覆盖的是"两台设备通过服务端收敛"这条完整链路，包括：
/// 配对鉴权、幂等推送、排除来源设备的拉取、以及客户端应用远端事件后
/// 不再回推（打环保险）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 关键：flutter_test 会装一个 HttpOverrides，把所有 HTTP 请求都拦成 400
  // （为的是不让 widget 测试真的去下载图片）。端到端测试必须关掉它，
  // 否则看到的是"服务端一直返回 400"这种假象。
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

  const deviceA = 'dev_e2e_a';
  const deviceB = 'dev_e2e_b';

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
    expect(result, isNotNull, reason: '配对应当成功');
    // 配对码是一次性的：同一个码不该能用第二次
    final again = await SyncClient(baseUrl: baseUrl, token: '').pair(
      code: code,
      deviceId: 'someone_else',
      deviceName: 'x',
    );
    expect(again, isNull, reason: '配对码必须一次性');
    return SyncClient(baseUrl: baseUrl, token: result!.token);
  }

  setUpAll(() async {});
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_e2e_srv');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';

    rootA = await Directory.systemTemp.createTemp('cs_e2e_a');
    rootB = await Directory.systemTemp.createTemp('cs_e2e_b');
    dbA = await openAt(rootA, deviceA);
    dbB = await openAt(rootB, deviceB);
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

  test('健康检查不需要鉴权', () async {
    final client = SyncClient(baseUrl: baseUrl, token: '');
    expect(await client.health(), isTrue);
    final anonymous = SyncClient(baseUrl: baseUrl, token: '');
    expect(
      () => anonymous.pull(since: 0),
      throwsA(
        isA<SyncException>().having((e) => e.isUnauthorized, 'unauthorized', true),
      ),
    );
    client.close();
    anonymous.close();
  });

  test('A 推、B 拉：两端数据一致，且 A 拉不到自己的事件', () async {
    final clientA = await pairAs(deviceA);
    final clientB = await pairAs(deviceB);

    final groupId = await dbA.insert('groups', {'name': '一班'});
    await dbA.insert('students', {
      'name': '李四',
      'student_number': '02',
      'group_id': groupId,
    });

    final codecA = SyncEventCodec(dbA);
    final events = await codecA.readOutbox();
    final pushResponse = await clientA.push(events);
    expect(pushResponse.accepted, 2);
    expect(pushResponse.duplicates, 0);

    // 幂等：同一批再推一次，全部记为重复
    final replay = await clientA.push(events);
    expect(replay.duplicates, 2);
    expect(replay.accepted, 0);

    // A 拉不到自己的事件
    final pageForA = await clientA.pull(since: 0);
    expect(pageForA.events, isEmpty);

    // B 能拉到，并成功应用到本地
    final pageForB = await clientB.pull(since: 0);
    expect(pageForB.events, hasLength(2));
    final codecB = SyncEventCodec(dbB);
    for (final event in pageForB.events) {
      await codecB.applyRemote(event);
    }
    final studentsOnB = await dbB.query('students');
    expect(studentsOnB.single['name'], '李四');
    final groupsOnB = await dbB.query('groups');
    expect(studentsOnB.single['group_id'], groupsOnB.single['id']);

    clientA.close();
    clientB.close();
  });

  test('B 应用完 A 的事件后不会再推回去（打环保险）', () async {
    final clientA = await pairAs(deviceA);
    final clientB = await pairAs(deviceB);

    await dbA.insert('groups', {'name': '打环测试'});
    await clientA.push(await SyncEventCodec(dbA).readOutbox());

    final page = await clientB.pull(since: 0);
    final codecB = SyncEventCodec(dbB);
    for (final e in page.events) {
      await codecB.applyRemote(e);
    }
    expect(await dbB.query('sync_outbox'), isEmpty);

    clientA.close();
    clientB.close();
  });

  test('删除通过墓碑跨设备收敛', () async {
    final clientA = await pairAs(deviceA);
    final clientB = await pairAs(deviceB);

    final id = await dbA.insert('groups', {'name': '临时组'});
    await clientA.push(await SyncEventCodec(dbA).readOutbox());

    await dbA.delete('groups', where: 'id = ?', whereArgs: [id]);
    final deleteEvents = await SyncEventCodec(dbA).readOutbox();
    expect(
      deleteEvents.where((e) => e.op.name == 'delete'),
      hasLength(1),
      reason: '删除必须产生一条 delete 事件',
    );
    await clientA.push(deleteEvents);

    final page = await clientB.pull(since: 0);
    final codecB = SyncEventCodec(dbB);
    for (final e in page.events) {
      await codecB.applyRemote(e);
    }
    // B 上这一行必须变成墓碑（不是消失），这样"先删后到"的顺序也能收敛
    final rows = await dbB.query('groups');
    final deleted = rows.where((r) => r['deleted_at'] != null).toList();
    expect(deleted, hasLength(1));

    clientA.close();
    clientB.close();
  });
}
