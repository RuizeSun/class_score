import 'dart:convert';
import 'dart:io';

import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 管理后台的读接口与允许列规则。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late HttpClient http;
  late String session;

  Future<(int, Map<String, dynamic>)> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? bearer = '__session__',
  }) async {
    final req = await http.openUrl(method, Uri.parse('$baseUrl$path'));
    req.headers.contentType = ContentType.json;
    final use = bearer == '__session__' ? session : bearer;
    if (use != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $use');
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

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_admin_api');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    final token = ensureAdminToken(serverDb)!;
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    http = HttpClient();
    final (status, json) = await send(
      'POST',
      '/admin/api/login',
      body: {'token': token},
      bearer: null,
    );
    expect(status, 200);
    session = json['session'] as String;
  });

  tearDown(() async {
    http.close(force: true);
    await server.close(force: true);
    serverDb.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 往服务端塞一条事件，模拟一台设备推上来的数据。
  void seedEvent({
    required String table,
    required String uid,
    required Map<String, dynamic> payload,
    String deviceId = 'dev_seed',
    int rev = 1,
    String op = 'upsert',
  }) {
    appendEvent(
      serverDb,
      deviceId: deviceId,
      table: table,
      uid: uid,
      op: op,
      rev: rev,
      revDevice: deviceId,
      payload: jsonEncode(payload),
    );
  }

  test('概览返回协议版本、表行数、设备数与最大 seq', () async {
    seedEvent(
      table: 'groups',
      uid: 'grp_1',
      payload: {'name': '一班'},
    );
    seedEvent(
      table: 'groups',
      uid: 'grp_2',
      payload: {'name': '二班'},
      op: 'delete',
      rev: 2,
    );
    final (status, json) = await send('GET', '/admin/api/overview');
    expect(status, 200);
    expect(json['protocol'], isA<int>());
    expect(json['event_count'], 2);
    final tables = (json['tables'] as Map).cast<String, dynamic>();
    expect((tables['groups'] as Map)['live'], 1);
    expect((tables['groups'] as Map)['deleted'], 1);
    // 每一张同步表都要出现，否则后台会漏掉某张表
    for (final name in const [
      'groups',
      'students',
      'score_items',
      'score_records',
      'course_schedule',
      'schedule_adjustment',
      'app_settings',
    ]) {
      expect(tables.containsKey(name), isTrue, reason: '概览缺少 $name');
    }
  });

  test('设备列表带事件数与最近活跃时间；可撤销', () async {
    final code = issuePairingCode(serverDb);
    await send(
      'POST',
      '/pair',
      body: {'code': code, 'device_id': 'dev_list', 'name': '大屏'},
      bearer: null,
    );
    seedEvent(
      table: 'groups',
      uid: 'grp_x',
      payload: {'name': '一班'},
      deviceId: 'dev_list',
    );

    final (status, json) = await send('GET', '/admin/api/devices');
    expect(status, 200);
    final list = (json['devices'] as List).cast<Map<String, dynamic>>();
    final dev = list.firstWhere((d) => d['id'] == 'dev_list');
    expect(dev['name'], '大屏');
    expect(dev['events'], 1);
    expect(dev['last_event_at'], isNotNull);

    final (revoked, _) = await send('DELETE', '/admin/api/devices/dev_list');
    expect(revoked, 200);
    final after = (await send('GET', '/admin/api/devices'))
        .$2['devices'] as List;
    expect(after.any((d) => (d as Map)['id'] == 'dev_list'), isFalse);
  });

  test('撤销设备之后该设备的 token 立即失效', () async {
    final code = issuePairingCode(serverDb);
    final (_, pairJson) = await send(
      'POST',
      '/pair',
      body: {'code': code, 'device_id': 'dev_gone', 'name': 'x'},
      bearer: null,
    );
    final token = pairJson['token'] as String;

    // 撤销前能拉
    var (status, _) = await send(
      'GET',
      '/sync/pull?since=0',
      bearer: token,
    );
    expect(status, 200);

    await send('DELETE', '/admin/api/devices/dev_gone');

    (status, _) = await send('GET', '/sync/pull?since=0', bearer: token);
    expect(status, 401, reason: '撤销后必须拒绝该设备的 token');
  });

  test('表浏览：分页、搜索、含墓碑开关', () async {
    for (var i = 0; i < 5; i++) {
      seedEvent(
        table: 'students',
        uid: 'stu_$i',
        payload: {'name': '学生$i', 'student_number': '$i', 'group_uid': null},
        rev: i + 1,
      );
    }
    seedEvent(
      table: 'students',
      uid: 'stu_dead',
      payload: {'name': '已删'},
      op: 'delete',
      rev: 99,
    );

    var (status, json) = await send(
      'GET',
      '/admin/api/table/students?limit=2',
    );
    expect(status, 200);
    expect(json['total'], 5, reason: '默认不含墓碑');
    expect((json['rows'] as List), hasLength(2));

    (status, json) = await send(
      'GET',
      '/admin/api/table/students?deleted=1',
    );
    expect(json['total'], 6);

    (status, json) = await send(
      'GET',
      '/admin/api/table/students?q=学生3',
    );
    expect(json['total'], 1);
    final row = (json['rows'] as List).single as Map<String, dynamic>;
    expect((row['data'] as Map)['name'], '学生3');

    (status, json) = await send('GET', '/admin/api/table/nope');
    expect(status, 400, reason: '未知表必须 400');
  });

  test('允许编辑的列排除了外键与语义主键', () async {
    final (_, students) = await send('GET', '/admin/api/table/students');
    final editable = (students['editable'] as List).cast<String>();
    expect(editable, contains('name'));
    expect(editable, contains('student_number'));
    expect(editable, isNot(contains('group_id')), reason: '外键不许在这里改');

    final (_, records) = await send('GET', '/admin/api/table/score_records');
    final recEditable = (records['editable'] as List).cast<String>();
    expect(recEditable, contains('score'));
    expect(recEditable, contains('reason'));
    expect(recEditable, isNot(contains('score_item_id')));
    expect(recEditable, isNot(contains('target_id')));
    expect(recEditable, isNot(contains('target_type')));

    final (_, settings) = await send('GET', '/admin/api/table/app_settings');
    final setEditable = (settings['editable'] as List).cast<String>();
    expect(setEditable, contains('value'));
    expect(setEditable, isNot(contains('key')), reason: 'key 是语义主键');

    final (_, adj) = await send(
      'GET',
      '/admin/api/table/schedule_adjustment',
    );
    final adjEditable = (adj['editable'] as List).cast<String>();
    expect(adjEditable, isNot(contains('date')));
    expect(adjEditable, contains('weekday'));
  });

  test('生成配对码后可以在概览里看到', () async {
    final (status, json) = await send('POST', '/admin/api/pairing');
    expect(status, 200);
    final code = json['code'] as String;
    expect(code, hasLength(6));

    final (_, overview) = await send('GET', '/admin/api/overview');
    expect(overview['pairing_code'], code);
    expect(overview['pairing_expires_at'], isNotNull);
  });

  test('审计记录包含登录与生成配对码', () async {
    await send('POST', '/admin/api/pairing');
    final (status, json) = await send('GET', '/admin/api/audit');
    expect(status, 200);
    final actions = (json['entries'] as List)
        .map((e) => (e as Map)['action'])
        .toList();
    expect(actions, contains('login'));
    expect(actions, contains('issue_pairing_code'));
  });

  test('静态资源带 CSP，且不含内联脚本', () async {
    final req = await http.getUrl(Uri.parse('$baseUrl/admin'));
    final res = await req.close();
    expect(res.statusCode, 200);
    final csp = res.headers.value('content-security-policy');
    expect(csp, isNotNull);
    expect(csp, contains("default-src 'self'"));
    expect(csp, contains("script-src 'self'"));
    final body = await res.transform(utf8.decoder).join();
    // 有 <script src=...> 但不能有内联 <script>...</script>
    //
    // 路径必须是**绝对**的 /admin/admin.js：页面挂在 /admin 上，
    // 相对路径 "admin.js" 会被浏览器解析成 /admin.js —— 而路由里没有这个
    // 地址，表现为"页面出来了但样式和脚本 404"，且只在浏览器里能发现。
    expect(body.contains('src="/admin/admin.js"'), isTrue);
    expect(body.contains('href="/admin/admin.css"'), isTrue);
    expect(
      RegExp(r'<script(?![^>]*\bsrc=)[^>]*>').hasMatch(body),
      isFalse,
      reason: 'CSP 禁止内联脚本，页面里不能有 <script> 正文',
    );
  });

  test('关闭管理后台后 /admin 返回 404', () async {
    final closed = await serveSync(
      db: serverDb,
      host: '127.0.0.1',
      port: 0,
      admin: const AdminConfig(enabled: false),
    );
    try {
      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${closed.port}/admin'),
      );
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 404);
      client.close(force: true);
    } finally {
      await closed.close(force: true);
    }
  });

  test('设备不能用保留前缀 srv_ 配对', () async {
    final code = issuePairingCode(serverDb);
    final (status, _) = await send(
      'POST',
      '/pair',
      body: {'code': code, 'device_id': 'srv_admin', 'name': '冒充'},
      bearer: null,
    );
    expect(status, 400, reason: 'srv_ 前缀留给管理员事件源');
  });
}