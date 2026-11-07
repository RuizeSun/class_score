import 'dart:convert';
import 'dart:io';

import 'package:class_score_server/sync_server.dart';
import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// rev 的信任边界。
///
/// rev 在客户端是 Lamport 时钟、由设备自行编号，但**不能是任意 int64**：
/// 服务端 `nextEventRev()` 用 `MAX(rev) + 1` 给管理员编辑取号，一台设备推来
/// `rev = 2^63-1` 就会让 `+1` 回绕成负数（Dart 实测），此后所有管理员编辑与
/// 其它设备的写入在 LWW 里**永久输**。这组测试锁定：尖峰被拒收、
/// 全局取号不溢出、合法写入不受影响。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late String token;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_rev_bound');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';

    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('$baseUrl/pair'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'code': issuePairingCode(serverDb),
      'device_id': 'dev_rev',
      'name': 'x',
    }));
    final res = await req.close();
    token = (jsonDecode(await res.transform(utf8.decoder).join()) as Map)['token']
        as String;
    client.close();
  });

  tearDown(() async {
    await server.close(force: true);
    serverDb.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<Map<String, dynamic>> push(List<Object?> events) async {
    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('$baseUrl/sync/push'));
    req.headers.contentType = ContentType.json;
    req.headers.set('authorization', 'Bearer $token');
    req.write(jsonEncode({'events': events}));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    client.close();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Map<String, dynamic> ev(String uid, int rev, Map<String, dynamic> data) =>
      {'t': 'groups', 'u': uid, 'o': 'upsert', 'r': rev, 'd': 'dev_rev', 'x': data};

  test('rev = 2^63-1 的尖峰被拒收，不进入 events/latest', () async {
    final poisoned = 9223372036854775807;
    final body = await push([
      ev('grp_poison', poisoned, {'name': '毒'}),
      ev('grp_ok', 1, {'name': '正常'}),
    ]);
    expect(body['accepted'], 1, reason: '正常那条要能进');
    expect(body['rejected'], 1, reason: '尖峰必须被拒收');
    expect(
      serverDb.select("SELECT 1 FROM latest WHERE uid = 'grp_poison'"),
      isEmpty,
      reason: '毒事件不能物化',
    );
    // 全局取号必须仍然健康
    expect(nextEventRev(serverDb), 2, reason: 'MAX(rev) 不被尖峰抬高');
  });

  test('rev = 0 与负数同样被拒收', () async {
    final body = await push([
      ev('grp_zero', 0, {'name': 'x'}),
      ev('grp_neg', -5, {'name': 'x'}),
    ]);
    expect(body['accepted'], 0);
    expect(body['rejected'], 2);
  });

  test('恰好等于 maxSafeRev 的 rev 可以入库（边界不误伤）', () async {
    final body = await push([ev('grp_edge', maxSafeRev, {'name': '边界'})]);
    expect(body['accepted'], 1);
    expect(
      serverDb.select("SELECT rev FROM latest WHERE uid = 'grp_edge'").first['rev'],
      maxSafeRev,
    );
  });

  test('管理员编辑在尖峰被拒后仍能拿到正常的 rev', () async {
    await push([ev('grp_ok', 1, {'name': '正常'})]);
    final rev = nextEventRev(serverDb);
    expect(rev, 2);
    expect(rev, greaterThan(0), reason: '绝不能拿到溢出的负号');
  });

  test('nextEventRev 在 rev 顶到上限时不再 +1（防回绕）', () async {
    serverDb.execute(
      "INSERT INTO events(device_id, tbl, uid, op, rev, rev_device, payload, created_at) "
      "VALUES ('dev_rev', 'groups', 'grp_top', 'upsert', ?, 'dev_rev', '{}', 'now')",
      [maxSafeRev],
    );
    expect(nextEventRev(serverDb), maxSafeRev, reason: '停在上限，绝不发出负号');
  });

  test('rev_device 冒充 srv_admin 会被改写成来源设备 id', () async {
    await push([
      {'t': 'groups', 'u': 'grp_spoof', 'o': 'upsert', 'r': 1, 'd': 'srv_admin',
       'x': {'name': '冒充'}},
    ]);
    final row = serverDb
        .select("SELECT rev_device FROM latest WHERE uid = 'grp_spoof'")
        .first;
    expect(row['rev_device'], 'dev_rev', reason: '设备不能把自己标成管理员');
  });
}
