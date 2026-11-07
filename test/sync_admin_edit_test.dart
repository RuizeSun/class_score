import 'dart:convert';
import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_client.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 管理员在后台改一行，**真实设备必须能收到并应用**。
///
/// 这是整个后台最关键的一条性质。如果编辑只改了服务端的物化表 `latest`
/// 而没有追加事件，后台会显示"已改"，所有设备却永远看不到——
/// 而且没有任何界面能发现这种脱同步。所以这里从 HTTP 一路断言到
/// 设备本地库的字段值。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();

  late Directory root;
  late Directory rootDevice;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late Database deviceDb;
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
    root = await Directory.systemTemp.createTemp('cs_admin_edit');
    rootDevice = await Directory.systemTemp.createTemp('cs_admin_edit_dev');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    final token = ensureAdminToken(serverDb)!;
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    http = HttpClient();
    deviceDb = await DatabaseHelper.openIndependent(
      p.join(rootDevice.path, 'data', 'score.db'),
    );
    await deviceDb.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      ['dev_admin_e2e'],
    );
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
    await deviceDb.close();
    for (final dir in [root, rootDevice]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  /// 设备侧：把本地 outbox 推上去，然后拉到游标为止。
  Future<void> syncDevice(SyncClient client) async {
    final codec = SyncEventCodec(deviceDb);
    final events = await codec.readOutbox();
    if (events.isNotEmpty) {
      await client.push(events);
      // 与 SyncEngine._push 一致：推送成功后从 outbox 删除，否则后面
      // "应用远端事件不回推"的断言会被这些待推送的本地事件污染。
      final seqs = events.map((e) => e.seq!).toList();
      await deviceDb.delete(
        'sync_outbox',
        where: 'seq IN (${List.filled(seqs.length, '?').join(',')})',
        whereArgs: seqs,
      );
    }
    final page = await client.pull(since: 0);
    for (final event in page.events) {
      await codec.applyRemote(event);
    }
  }

  test('管理员改分 → 设备下次拉取就能看到新值，且不会回推', () async {
    // 1) 设备配对
    final code = issuePairingCode(serverDb);
    final (_, pairJson) = await send(
      'POST',
      '/pair',
      body: {
        'code': code,
        'device_id': 'dev_admin_e2e',
        'name': 'classroom',
      },
      bearer: null,
    );
    final deviceToken = pairJson['token'] as String;
    final client = SyncClient(baseUrl: baseUrl, token: deviceToken);

    // 2) 设备本地建一条评分记录并推上去
    final groupId = await deviceDb.insert('groups', {'name': '一班'});
    final studentId = await deviceDb.insert('students', {
      'name': '张三',
      'student_number': '01',
      'group_id': groupId,
    });
    final recordId = await deviceDb.insert('score_records', {
      'target_type': 'student',
      'target_id': studentId,
      'score': 5.0,
      'reason': '课堂表现',
      'create_time': DateTime.now().toIso8601String(),
      'period': 1,
    });
    await syncDevice(client);

    final recordUid = (await deviceDb.query(
      'score_records',
      columns: ['uid'],
      where: 'id = ?',
      whereArgs: [recordId],
    )).single['uid'] as String;

    // 3) 管理员在后台改这一条的分值与原因
    final (editStatus, editJson) = await send(
      'PATCH',
      '/admin/api/table/score_records/$recordUid',
      body: {
        'data': {'score': 8.0, 'reason': '管理员修正'},
      },
    );
    expect(editStatus, 200, reason: '编辑应当成功：$editJson');
    final adminRev = editJson['rev'] as int;

    // 4) 关键断言：服务端确实追加了一条事件（而不是只改 latest）
    final events = serverDb.select(
      "SELECT device_id, rev, rev_device, payload FROM events "
      "WHERE tbl = 'score_records' AND uid = ? ORDER BY seq",
      [recordUid],
    );
    expect(events, hasLength(2), reason: '应当有"设备推的"与"管理员改的"两条');
    final adminEvent = events.last;
    expect(adminEvent['device_id'], kAdminDeviceId);
    expect(adminEvent['rev_device'], kAdminDeviceId);
    expect(adminEvent['rev'], adminRev);
    expect(
      adminRev,
      greaterThan(events.first['rev'] as int),
      reason: '管理员的 rev 必须取全局最大 +1，否则会被设备的旧版本盖回去',
    );

    // 5) 设备拉取并应用
    final codec = SyncEventCodec(deviceDb);
    final page = await client.pull(since: 0);
    for (final event in page.events) {
      await codec.applyRemote(event);
    }
    final after = (await deviceDb.query(
      'score_records',
      where: 'id = ?',
      whereArgs: [recordId],
    )).single;
    expect(after['score'], 8.0, reason: '设备本地必须变成管理员改的值');
    expect(after['reason'], '管理员修正');

    // 6) 应用远端事件不能记账（否则设备会把管理员的改动再推回去）
    expect(await deviceDb.query('sync_outbox'), isEmpty);

    client.close();
  });

  test('管理员改小组名 → 设备本地跟着变', () async {
    final code = issuePairingCode(serverDb);
    final (_, pairJson) = await send(
      'POST',
      '/pair',
      body: {'code': code, 'device_id': 'dev_admin_e2e', 'name': 'x'},
      bearer: null,
    );
    final client = SyncClient(
      baseUrl: baseUrl,
      token: pairJson['token'] as String,
    );

    final groupId = await deviceDb.insert('groups', {'name': '旧组名'});
    await syncDevice(client);
    final uid = (await deviceDb.query(
      'groups',
      columns: ['uid'],
      where: 'id = ?',
      whereArgs: [groupId],
    )).single['uid'] as String;

    final (status, _) = await send(
      'PATCH',
      '/admin/api/table/groups/$uid',
      body: {
        'data': {'name': '管理员改过的组名'},
      },
    );
    expect(status, 200);

    final codec = SyncEventCodec(deviceDb);
    for (final event in (await client.pull(since: 0)).events) {
      await codec.applyRemote(event);
    }
    expect(
      (await deviceDb.query('groups')).single['name'],
      '管理员改过的组名',
    );
    client.close();
  });

  test('编辑墓碑行被拒绝（恢复应当由设备端做）', () async {
    final code = issuePairingCode(serverDb);
    final (_, pairJson) = await send(
      'POST',
      '/pair',
      body: {'code': code, 'device_id': 'dev_admin_e2e', 'name': 'x'},
      bearer: null,
    );
    final client = SyncClient(
      baseUrl: baseUrl,
      token: pairJson['token'] as String,
    );

    final groupId = await deviceDb.insert('groups', {'name': '要删的组'});
    await syncDevice(client);
    final uid = (await deviceDb.query(
      'groups',
      columns: ['uid'],
      where: 'id = ?',
      whereArgs: [groupId],
    )).single['uid'] as String;

    await deviceDb.delete('groups', where: 'id = ?', whereArgs: [groupId]);
    await syncDevice(client);

    final (status, json) = await send(
      'PATCH',
      '/admin/api/table/groups/$uid',
      body: {
        'data': {'name': '复活'},
      },
    );
    expect(status, 400);
    expect(json['error'], contains('已删除'));
    client.close();
  });

  test('非法列、类型不符、不存在的 uid 都被拒绝', () async {
    final code = issuePairingCode(serverDb);
    final (_, pairJson) = await send(
      'POST',
      '/pair',
      body: {'code': code, 'device_id': 'dev_admin_e2e', 'name': 'x'},
      bearer: null,
    );
    final client = SyncClient(
      baseUrl: baseUrl,
      token: pairJson['token'] as String,
    );

    final groupId = await deviceDb.insert('groups', {'name': '一班'});
    await syncDevice(client);
    final uid = (await deviceDb.query(
      'groups',
      columns: ['uid'],
      where: 'id = ?',
      whereArgs: [groupId],
    )).single['uid'] as String;

    // 外键列
    final (fkStatus, fkJson) = await send(
      'PATCH',
      '/admin/api/table/students/some_uid',
      body: {
        'data': {'group_id': 1},
      },
    );
    // 行不存在 → 404；换个存在的学生再测列校验
    expect(fkStatus, 404, reason: '${fkJson['error']}');

    // 类型不符：name 本来是字符串
    final (typeStatus, typeJson) = await send(
      'PATCH',
      '/admin/api/table/groups/$uid',
      body: {
        'data': {'name': 123},
      },
    );
    expect(typeStatus, 400);
    expect(typeJson['error'], contains('类型'));

    // 不存在的列
    final (colStatus, colJson) = await send(
      'PATCH',
      '/admin/api/table/groups/$uid',
      body: {
        'data': {'uid': 'hack'},
      },
    );
    expect(colStatus, 400);
    expect(colJson['error'], contains('不可编辑'));

    // 不存在的 uid
    final (missingStatus, _) = await send(
      'PATCH',
      '/admin/api/table/groups/grp_not_exist',
      body: {
        'data': {'name': 'x'},
      },
    );
    expect(missingStatus, 404);

    // 空 patch
    final (emptyStatus, _) = await send(
      'PATCH',
      '/admin/api/table/groups/$uid',
      body: {'data': const {}},
    );
    expect(emptyStatus, 400);
    client.close();
  });

  test('编辑会留下审计记录（含改动前后）', () async {
    final code = issuePairingCode(serverDb);
    final (_, pairJson) = await send(
      'POST',
      '/pair',
      body: {'code': code, 'device_id': 'dev_admin_e2e', 'name': 'x'},
      bearer: null,
    );
    final client = SyncClient(
      baseUrl: baseUrl,
      token: pairJson['token'] as String,
    );
    final groupId = await deviceDb.insert('groups', {'name': '原名'});
    await syncDevice(client);
    final uid = (await deviceDb.query(
      'groups',
      columns: ['uid'],
      where: 'id = ?',
      whereArgs: [groupId],
    )).single['uid'] as String;

    await send(
      'PATCH',
      '/admin/api/table/groups/$uid',
      body: {
        'data': {'name': '改名'},
      },
    );

    final (_, audit) = await send('GET', '/admin/api/audit');
    final entry = (audit['entries'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((e) => e['action'] == 'edit');
    expect(entry['table'], 'groups');
    expect(entry['uid'], uid);
    expect((entry['before'] as Map)['name'], '原名');
    expect((entry['after'] as Map)['name'], '改名');
    client.close();
  });
}
