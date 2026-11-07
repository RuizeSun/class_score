import 'dart:io';

import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 配对码是 6 位数字，理论上可以穷举；没有限流时脚本几小时就能走一遍。
///
/// 这里直接发 HTTP 而不是用 SyncClient：要断言的是服务端行为（401 → 429），
/// 客户端只需要知道"失败了"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late HttpClient http;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_brute');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.close(force: true);
    serverDb.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<int> tryPair(String code) async {
    final req = await http.postUrl(Uri.parse('$baseUrl/pair'));
    req.headers.contentType = ContentType.json;
    req.write('{"code":"$code","device_id":"brute","name":"x"}');
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  }

  test('连续错误配对达到阈值后返回 429', () async {
    final codes = <int>[];
    for (var i = 0; i < kPairingMaxFailures + 3; i++) {
      codes.add(await tryPair((300000 + i).toString()));
    }
    expect(
      codes.take(kPairingMaxFailures),
      everyElement(401),
      reason: '阈值内应当是普通失败',
    );
    expect(
      codes.skip(kPairingMaxFailures),
      everyElement(429),
      reason: '超过阈值必须限流',
    );
  });

  test('锁定期内即使配对码正确也拒绝', () async {
    for (var i = 0; i < kPairingMaxFailures; i++) {
      await tryPair((400000 + i).toString());
    }
    final realCode = issuePairingCode(serverDb);
    expect(
      await tryPair(realCode),
      429,
      reason: '锁定期内连正确的码也不该放行',
    );
  });

  test('没有失败记录时，正常配对不受影响', () async {
    final code = issuePairingCode(serverDb);
    expect(await tryPair(code), 200);
  });

  // 限流用的失败计数行和真配对码存在**同一张表**里，code 是
  // `__failed__::<来源IP>`、used_at=NULL、expires_at=+3650 天。
  // 曾经 `_pair` 只按 code 精确匹配，于是"先输错一次"就能把这条哨兵行
  // 当成配对码换到有效设备 token —— 完全跳过真正的配对码。
  test('限流哨兵行不能当成配对码换 token', () async {
    expect(await tryPair('000000'), 401);
    final sentinel = serverDb
        .select("SELECT code FROM pairing WHERE code LIKE '__failed__::%'")
        .first['code'] as String;
    expect(sentinel, startsWith('__failed__::'));

    expect(
      await tryPair(sentinel),
      401,
      reason: '哨兵行不是配对码，绝不能换到 token',
    );
    expect(
      serverDb.select("SELECT id FROM devices WHERE id = 'brute'"),
      isEmpty,
      reason: '攻击者不应被写成一台已配对设备',
    );
  });

  // 形状校验是上面那条的第二道防线：配对码永远是 6 位数字。
  test('非 6 位数字的配对码一律拒绝', () async {
    for (final bad in ['abcdef', '12345', '1234567', '', '__failed__::1.2.3.4']) {
      expect(await tryPair(bad), anyOf(400, 401), reason: '非法形状：$bad');
    }
  });
}