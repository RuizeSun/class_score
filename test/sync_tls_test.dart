import 'dart:convert';
import 'dart:io';

import 'package:class_score/sync/sync_client.dart';
import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 传输层安全：客户端必须能走 HTTPS，且**只信任指定的那张证书**。
///
/// 背景：服务端默认是明文 HTTP，配对码与设备 token 都在网络上是明文。
/// 现在支持 --cert/--key 启用 TLS；客户端支持显式指定服务端证书（自签名）。
///
/// 证书是 `test/fixtures/tls/` 里**提交进仓库**的固定夹具，不是运行时生成的：
/// 早先的版本在 `server/build/tls/` 现生成，而 build 目录会被清理，
/// 于是这套测试在别人机器上、以及每次清理构建产物之后都直接失败
/// （实测：3 条全部 PathNotFound）。夹具里的私钥**仅供测试**，
/// 它签的是一张 10 年后过期的自签名证书，不对应任何真实服务端。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final certPath = p.join('test', 'fixtures', 'tls', 'cert.pem');
  final keyPath = p.join('test', 'fixtures', 'tls', 'key.pem');

  late Directory root;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late List<int> serverCertPem;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_tls_test');
    serverCertPem = File(certPath).readAsBytesSync();
    final ctx = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath);
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    server = await serveSync(
      db: serverDb,
      host: '127.0.0.1',
      port: 0,
      securityContext: ctx,
    );
    baseUrl = 'https://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    serverDb.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('指定证书后，客户端可以完成配对与拉取（全程 TLS）', () async {
    final code = issuePairingCode(serverDb);
    final client = SyncClient(
      baseUrl: baseUrl,
      token: '',
      trustedCertificatePem: serverCertPem,
    );
    expect(await client.health(), isTrue, reason: 'https 探活应当成功');
    final result = await client.pair(
      code: code,
      deviceId: 'dev_tls_test',
      deviceName: 'test',
    );
    expect(result, isNotNull, reason: 'TLS 下的配对应当成功');
    client.close();

    final authed = SyncClient(
      baseUrl: baseUrl,
      token: result!.token,
      trustedCertificatePem: serverCertPem,
    );
    final page = await authed.pull(since: 0);
    expect(page.events, isEmpty);
    authed.close();
  });

  test('不给证书时拒绝连接（不会静默接受自签名）', () async {
    final client = SyncClient(baseUrl: baseUrl, token: '');
    expect(
      await client.health(),
      isFalse,
      reason: '没有指定证书时，自签名服务端应当被视为不可信',
    );
    client.close();
  });

  test('给错证书时同样拒绝（按内容固定，不是跳过校验）', () async {
    // 生成一张别处的证书来冒充
    final other =
        '-----BEGIN CERTIFICATE-----\nMIIDazCCAlOgAwIBAgIUfake\n'
        '-----END CERTIFICATE-----\n';
    final client = SyncClient(
      baseUrl: baseUrl,
      token: '',
      trustedCertificatePem: other.codeUnits,
    );
    expect(await client.health(), isFalse, reason: '错误的证书不能被接受');
    client.close();
  });

  test('管理后台也走同一条 TLS 通道', () async {
    final token = ensureAdminToken(serverDb)!;
    final session = await clientLogin(baseUrl, serverCertPem, token);
    expect(session, isNotNull, reason: 'https 下应当能登录管理后台');

    final client = HttpClient()
      ..badCertificateCallback = _pinTo(serverCertPem);
    try {
      final req = await client.getUrl(Uri.parse('$baseUrl/admin'));
      final res = await req.close();
      expect(res.statusCode, 200);
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  });
}

Future<String?> clientLogin(
  String baseUrl,
  List<int> pem,
  String token,
) async {
  final client = HttpClient()..badCertificateCallback = _pinTo(pem);
  try {
    final req = await client.postUrl(Uri.parse('$baseUrl/admin/api/login'));
    req.headers.contentType = ContentType.json;
    req.write('{"token":"$token"}');
    final res = await req.close();
    final text = await res.transform(const SystemEncoding().decoder).join();
    if (res.statusCode != 200) return null;
    final match = RegExp(r'"session":"([^"]+)"').firstMatch(text);
    return match?.group(1);
  } finally {
    client.close(force: true);
  }
}

bool Function(X509Certificate, String, int) _pinTo(List<int> pem) {
  final text = String.fromCharCodes(pem);
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
  ).firstMatch(text);
  final pinned = base64Decode(match!.group(1)!.replaceAll(RegExp(r'\s'), ''));
  return (cert, host, port) {
    if (cert.der.length != pinned.length) return false;
    for (var i = 0; i < pinned.length; i++) {
      if (cert.der[i] != pinned[i]) return false;
    }
    return true;
  };
}
