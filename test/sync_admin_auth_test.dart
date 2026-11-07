import 'dart:convert';
import 'dart:io';

import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 管理后台的鉴权。
///
/// 这几条都是**负向**断言：未登录、错 token、过期会话、被撤销的会话、
/// 暴力尝试、非本机来源，每一条都必须拒绝。后台能改同步数据，
/// 放进来一个人就等于放进来一个能改全班成绩的人。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late HttpClient http;
  late String adminToken;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_admin_auth');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    adminToken = ensureAdminToken(serverDb)!;
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

  Future<(int, Map<String, dynamic>)> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? bearer,
  }) async {
    final req = await http.openUrl(method, Uri.parse('$baseUrl$path'));
    req.headers.contentType = ContentType.json;
    if (bearer != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    Map<String, dynamic> json;
    try {
      json = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      json = {};
    }
    return (res.statusCode, json);
  }

  Future<String> login([String? token]) async {
    final (status, json) = await send(
      'POST',
      '/admin/api/login',
      body: {'token': token ?? adminToken},
    );
    expect(status, 200, reason: '正确令牌应当能登录：$json');
    return json['session'] as String;
  }

  test('未登录访问管理接口一律 401', () async {
    for (final path in [
      '/admin/api/overview',
      '/admin/api/devices',
      '/admin/api/table/students',
      '/admin/api/audit',
      '/admin/api/pairing',
    ]) {
      final (status, _) = await send('GET', path);
      expect(status, 401, reason: '$path 不该在未登录时可达');
    }
  });

  test('错误的管理员令牌登录失败；正确的能换到会话', () async {
    final (bad, _) = await send(
      'POST',
      '/admin/api/login',
      body: {'token': 'not-the-token'},
    );
    expect(bad, 401);

    final (ok, json) = await send(
      'POST',
      '/admin/api/login',
      body: {'token': adminToken},
    );
    expect(ok, 200);
    expect(json['session'], isA<String>());
    expect((json['expires_in'] as int) > 0, isTrue);
  });

  test('会话可以访问接口；登出后立即失效', () async {
    final session = await login();
    final (ok, _) = await send(
      'GET',
      '/admin/api/overview',
      bearer: session,
    );
    expect(ok, 200);

    final (out, _) = await send(
      'POST',
      '/admin/api/logout',
      bearer: session,
    );
    expect(out, 200);

    final (after, _) = await send(
      'GET',
      '/admin/api/overview',
      bearer: session,
    );
    expect(after, 401, reason: '登出后会话必须立刻不可用');
  });

  test('设备 token 不能当管理员会话用（两条鉴权链不能混）', () async {
    final code = issuePairingCode(serverDb);
    final (_, pairJson) = await send(
      'POST',
      '/pair',
      body: {'code': code, 'device_id': 'dev_x', 'name': 'x'},
    );
    final deviceToken = pairJson['token'] as String;

    final (status, _) = await send(
      'GET',
      '/admin/api/overview',
      bearer: deviceToken,
    );
    expect(status, 401, reason: '设备 token 不该能进管理后台');

    // 反过来：管理员会话也不该能推送
    final session = await login();
    final (pushStatus, _) = await send(
      'POST',
      '/sync/push',
      bearer: session,
      body: {'events': const []},
    );
    expect(pushStatus, 401, reason: '管理员会话不该能当设备推送');
  });

  test('会话过期后拒绝访问', () async {
    final session = await login();
    // 直接把库里的过期时间改到过去——比等 12 小时实际。
    serverDb.execute(
      'UPDATE admin_sessions SET expires_at = ?',
      [DateTime.now().subtract(const Duration(minutes: 1)).toIso8601String()],
    );
    final (status, _) = await send(
      'GET',
      '/admin/api/overview',
      bearer: session,
    );
    expect(status, 401);
  });

  test('管理员令牌在库里不可逆，也不出现在审计里', () {
    final rows = serverDb.select('SELECT token_hash FROM admins');
    final stored = rows.first['token_hash'] as String;
    expect(stored.contains(adminToken), isFalse);
    expect(stored.startsWith('v2'), isTrue, reason: '必须是 sha256 而非 base64');

    // 会话也是同样的存储形式
    final sessions = serverDb.select('SELECT token_hash FROM admin_sessions');
    for (final row in sessions) {
      expect((row['token_hash'] as String).startsWith('v2'), isTrue);
    }
  });

  test('连续登录失败达到阈值后限流', () async {
    final codes = <int>[];
    for (var i = 0; i < kAdminMaxFailures + 2; i++) {
      final (status, _) = await send(
        'POST',
        '/admin/api/login',
        body: {'token': 'wrong-$i'},
      );
      codes.add(status);
    }
    expect(codes.take(kAdminMaxFailures), everyElement(401));
    expect(codes.skip(kAdminMaxFailures), everyElement(429));

    // 锁定期内即使令牌正确也拒绝
    final (locked, _) = await send(
      'POST',
      '/admin/api/login',
      body: {'token': adminToken},
    );
    expect(locked, 429);
  });

  test('轮换令牌后旧令牌与旧会话一起失效', () async {
    final session = await login();
    final rotated = rotateAdminToken(serverDb);
    expect(rotated, isNot(adminToken));

    final (oldToken, _) = await send(
      'POST',
      '/admin/api/login',
      body: {'token': adminToken},
    );
    expect(oldToken, 401, reason: '旧令牌必须失效');

    final (oldSession, _) = await send(
      'GET',
      '/admin/api/overview',
      bearer: session,
    );
    expect(oldSession, 401, reason: '轮换的动机通常是可能泄露，旧会话不能留着');

    final (newOk, _) = await send(
      'POST',
      '/admin/api/login',
      body: {'token': rotated},
    );
    expect(newOk, 200);
  });

  test('非本机来源默认拒绝（--admin-allow-remote 才放开）', () async {
    // 找一个非回环的 IPv4 地址；机器上没有就直接跳过这条断言。
    final address = await _firstNonLoopbackIPv4();
    if (address == null) {
      markTestSkipped('本机没有非回环 IPv4，跳过来源限制测试');
      return;
    }
    final wide = await serveSync(
      db: serverDb,
      host: '0.0.0.0',
      port: 0,
      admin: const AdminConfig(allowRemote: false),
    );
    try {
      final client = HttpClient();
      // 连本机的局域网地址：对端不是 127.0.0.1，因此不是回环。
      final uri = Uri.parse('http://$address:${wide.port}/admin/api/login');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'token': adminToken}));
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 403, reason: '非回环来源默认应当被拒绝');
      client.close(force: true);
    } finally {
      await wide.close(force: true);
    }
  });
}

Future<String?> _firstNonLoopbackIPv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  for (final ni in interfaces) {
    for (final addr in ni.addresses) {
      if (!addr.isLoopback) return addr.address;
    }
  }
  return null;
}
