import 'dart:convert';
import 'dart:io';

import 'package:class_score_server/sync_server.dart';
import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 服务端在"能收"这件事上的边界。
///
/// 这些都属于"一条坏输入让整条同步链停摆"的类别：客户端 `_push` 遇到 500
/// 会无限重试同一批，所以服务端必须逐条容错，并把拒收条数如实回报。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late String token;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_push_bounds');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';

    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('$baseUrl/pair'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'code': issuePairingCode(serverDb),
      'device_id': 'dev_push',
      'name': 'x',
    }));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    token = (jsonDecode(body) as Map)['token'] as String;
    client.close();
  });

  tearDown(() async {
    await server.close(force: true);
    serverDb.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> push(
    List<Object?> events, {
    Map<String, String>? headers,
  }) async {
    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('$baseUrl/sync/push'));
    req.headers.contentType = ContentType.json;
    req.headers.set('authorization', 'Bearer $token');
    headers?.forEach(req.headers.set);
    req.write(jsonEncode({'events': events}));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    client.close();
    return (res.statusCode, jsonDecode(text) as Map<String, dynamic>);
  }

  Map<String, dynamic> ev(String table, String uid, int rev, Map<String, dynamic> data) =>
      {'t': table, 'u': uid, 'o': 'upsert', 'r': rev, 'd': 'dev_push', 'x': data};

  test('一条坏事件不会让整批失败，好的照常入库', () async {
    final (status, body) = await push([
      ev('groups', 'grp_ok', 1, {'name': '一班'}),
      // 未知表名：服务端必须逐条拒收，而不是整批 500
      ev('students2', 'zzz', 1, {'name': 'x'}),
      ev('groups', 'grp_ok2', 2, {'name': '二班'}),
    ]);
    expect(status, 200, reason: '整批不该因为一条坏事件而 500');
    expect(body['accepted'], 2);
    expect(body['rejected'], 1);

    final latest = serverDb.select("SELECT uid FROM latest WHERE tbl = 'groups'");
    expect(latest.map((r) => r['uid']), containsAll(['grp_ok', 'grp_ok2']));
    expect(
      serverDb.select("SELECT 1 FROM latest WHERE tbl = 'students2'"),
      isEmpty,
      reason: '未知表名不能落成僵尸行',
    );
  });

  test('畸形事件（不是对象 / 缺字段）计入 rejected', () async {
    final (status, body) = await push([
      1,
      {'t': 'groups'}, // 缺 uid/rev
      ev('groups', 'grp_ok', 1, {'name': 'ok'}),
    ]);
    expect(status, 200);
    expect(body['accepted'], 1);
    expect(body['rejected'], 2);
  });

  test('超过单批上限直接 400', () async {
    final many = List.generate(
      kMaxPushEvents + 1,
      (i) => ev('groups', 'g$i', 1, {'name': 'x'}),
    );
    final (status, body) = await push(many);
    expect(status, 400);
    expect(body['error'], contains('too many'));
  });

  test('协议版本不一致返回 426', () async {
    final (status, body) = await push(
      [ev('groups', 'grp_v', 1, {'name': 'x'})],
      headers: {'x-sync-protocol': '${syncProtocolVersion + 1}'},
    );
    expect(status, 426, reason: '版本漂移必须明确拒绝，而不是静默产生解析不了的事件');
    expect(body['server_protocol'], syncProtocolVersion);
  });

  test('协议版本一致或缺失时正常放行', () async {
    final (s1, b1) = await push(
      [ev('groups', 'grp_a', 1, {'name': 'x'})],
      headers: {'x-sync-protocol': '$syncProtocolVersion'},
    );
    expect(s1, 200);
    expect(b1['accepted'], 1);

    // 缺失 header 保持兼容（老客户端）
    final (s2, b2) = await push([ev('groups', 'grp_b', 1, {'name': 'y'})]);
    expect(s2, 200);
    expect(b2['accepted'], 1);
  });

  test('重复推送同一批是幂等的', () async {
    final batch = [ev('groups', 'grp_dup', 1, {'name': 'x'})];
    final (_, first) = await push(batch);
    expect(first['accepted'], 1);
    final (_, second) = await push(batch);
    expect(second['accepted'], 0);
    expect(second['duplicates'], 1);
  });
}
