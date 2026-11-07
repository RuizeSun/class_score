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

/// 真实场景：**磁盘上已经有一个 v10 的旧库**，升级到 v11 之后首次配对。
///
/// 前面几个测试都是从新建的 v11 库出发的，而那些库在插入时就会记 outbox。
/// 真正会踩坑的是老用户：升级时历史行不会进 outbox，配对后如果只跑普通的
/// push/pull，那些数据永远上不去。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();

  const v10Schema = [
    '''CREATE TABLE groups (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)''',
    '''CREATE TABLE students (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, student_number TEXT NOT NULL DEFAULT '', group_id INTEGER NOT NULL, include_in_group_total INTEGER NOT NULL DEFAULT 1)''',
    '''CREATE TABLE score_records (id INTEGER PRIMARY KEY AUTOINCREMENT, target_type TEXT NOT NULL, target_id INTEGER NOT NULL, score REAL NOT NULL, reason TEXT, score_item_id INTEGER, custom_name TEXT, create_time TEXT NOT NULL, period INTEGER NOT NULL DEFAULT 1, is_quick INTEGER NOT NULL DEFAULT 0)''',
    '''CREATE TABLE score_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, default_score REAL NOT NULL, description TEXT NOT NULL)''',
    '''CREATE TABLE course_schedule (id INTEGER PRIMARY KEY AUTOINCREMENT, weekday INTEGER NOT NULL, course_name TEXT NOT NULL, start_time TEXT NOT NULL, end_time TEXT NOT NULL)''',
    '''CREATE TABLE schedule_adjustment (id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL UNIQUE, weekday INTEGER NOT NULL, created_at TEXT NOT NULL)''',
    '''CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)''',
    '''CREATE TABLE usb_keys (id INTEGER PRIMARY KEY AUTOINCREMENT, token TEXT NOT NULL, label TEXT NOT NULL, created_at TEXT NOT NULL)''',
    '''CREATE TABLE score_record_archives (id INTEGER PRIMARY KEY AUTOINCREMENT, record_id INTEGER NOT NULL, target_type TEXT NOT NULL, target_id INTEGER NOT NULL, score REAL NOT NULL, reason TEXT, score_item_id INTEGER, custom_name TEXT, create_time TEXT NOT NULL, period INTEGER NOT NULL DEFAULT 1, is_quick INTEGER NOT NULL DEFAULT 0, deleted_at TEXT NOT NULL)''',
    '''CREATE TABLE score_record_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, record_id INTEGER NOT NULL, action_type TEXT NOT NULL, field TEXT, old_value TEXT, new_value TEXT, content TEXT, log_time TEXT NOT NULL)''',
  ];

  late Directory serverRoot;
  late Directory deviceRoot;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late String dbPath;
  late Database db;

  setUp(() async {
    serverRoot = await Directory.systemTemp.createTemp('cs_legacy_srv');
    deviceRoot = await Directory.systemTemp.createTemp('cs_legacy_dev');
    serverDb = openServerDb(p.join(serverRoot.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    dbPath = p.join(deviceRoot.path, 'data', 'score.db');

    // 1) 先造一个 v10 的库并塞入历史数据
    final legacy = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 10,
        onCreate: (raw, _) async {
          for (final sql in v10Schema) {
            await raw.execute(sql);
          }
        },
      ),
    );
    final gid = await legacy.insert('groups', {'name': '一班'});
    await legacy.insert('students', {'name': '张三', 'student_number': '01', 'group_id': gid});
    await legacy.insert('students', {'name': '李四', 'student_number': '02', 'group_id': gid});
    await legacy.insert('score_items', {'name': '课堂表现', 'default_score': 2.0, 'description': ''});
    await legacy.insert('score_records', {'target_type': 'student', 'target_id': 1, 'score': 5.0, 'create_time': '2026-10-01T09:00:00', 'period': 1});
    await legacy.insert('score_records', {'target_type': 'student', 'target_id': 2, 'score': 3.0, 'create_time': '2026-10-01T09:05:00', 'period': 1});
    await legacy.insert('app_settings', {'key': 'current_period', 'value': '2'});
    await legacy.close();

    // 2) 用正式入口打开：触发 v10 → v11 迁移
    db = await DatabaseHelper.openIndependent(dbPath);
    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      ['dev_legacy'],
    );
  });

  tearDown(() async {
    await server.close(force: true);
    serverDb.dispose();
    await db.close();
    for (final dir in [serverRoot, deviceRoot]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('升级后历史行不在 outbox 里（这就是问题本身）', () async {
    expect(await db.query('sync_outbox'), isEmpty);
    expect((await db.query('students')), hasLength(2));
    for (final row in await db.query('students')) {
      expect(row['uid'], isNotNull, reason: '迁移会 backfill uid');
    }
  });

  test('首次会合把历史数据全部推上服务端', () async {
    final code = issuePairingCode(serverDb);
    final anon = SyncClient(baseUrl: baseUrl, token: '');
    final result = await anon.pair(code: code, deviceId: 'dev_legacy', deviceName: 'classroom');
    anon.close();
    final client = SyncClient(baseUrl: baseUrl, token: result!.token);

    final summaryBefore = await client.summary();
    expect(summaryBefore.isEmpty, isTrue, reason: '新服务端应当是空的');

    final codec = SyncEventCodec(db);
    expect(await codec.countLocalRows(), greaterThanOrEqualTo(5));

    final events = await codec.snapshotLocalRows(startRev: 0, deviceId: 'dev_legacy');
    for (var i = 0; i < events.length; i += 200) {
      await client.push(events.sublist(i, (i + 200).clamp(0, events.length)));
    }

    final summary = await client.summary();
    expect(summary.liveRows['groups'], 1);
    expect(summary.liveRows['students'], 2);
    expect(summary.liveRows['score_records'], 2);
    expect(summary.liveRows['app_settings'], greaterThanOrEqualTo(1));

    // 外键已翻译；服务端物化表里 group_uid 有值
    final rows = serverDb.select("SELECT payload FROM latest WHERE tbl = 'students' ORDER BY uid");
    expect(rows, hasLength(2));
    for (final row in rows) {
      final payload = (jsonDecode(row['payload'] as String) as Map).cast<String, dynamic>();
      expect(payload['group_uid'], isA<String>(), reason: '外键必须翻译成 uid');
      expect(payload.containsKey('group_id'), isFalse);
    }
    client.close();
  });

  test('上传后本地 lamport 被抬高，后续本地写入能继续赢', () async {
    final code = issuePairingCode(serverDb);
    final anon = SyncClient(baseUrl: baseUrl, token: '');
    final result = await anon.pair(code: code, deviceId: 'dev_legacy', deviceName: 'x');
    anon.close();
    final client = SyncClient(baseUrl: baseUrl, token: result!.token);

    final codec = SyncEventCodec(db);
    final events = await codec.snapshotLocalRows(startRev: 0, deviceId: 'dev_legacy');
    await client.push(events);
    await db.rawUpdate(
      "UPDATE sync_state SET value = MAX(CAST(value AS INTEGER), ?) WHERE key = 'lamport'",
      [events.last.rev],
    );

    final before = await db.query('sync_state', where: 'key = ?', whereArgs: ['lamport']);
    expect(int.parse(before.single['value'] as String), greaterThanOrEqualTo(events.last.rev));

    // 本地改名：新 rev 必须大于刚上传的
    final gid = (await db.query('groups')).single['id'] as int;
    await db.update('groups', {'name': '一班（改）'}, where: 'id = ?', whereArgs: [gid]);
    final after = (await db.query('groups')).single;
    expect(after['rev'] as int, greaterThan(events.last.rev));
    client.close();
  });
}
