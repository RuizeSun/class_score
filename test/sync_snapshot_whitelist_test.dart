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

/// 首次会合（snapshotLocalRows）必须和触发器遵守**同一份**设置白名单。
///
/// 两条路径的差别是关键：触发器用 `WHEN NEW.key IN (...)` 过滤，
/// 而首次会合是**绕开触发器直接扫表**。v11 迁移的 _backfill 又给
/// app_settings 的**所有**历史行补了 uid，于是老用户升级后第一次配对，
/// 整张设置表（pin_hash / 主题色 / 天气城市）都会被当成"历史数据"推上去。
///
/// 这曾经真实发生过：实测服务端 `latest` 里出现了
/// `{key: pin_hash, value: PIN_SECRET_ABC}` —— 解锁凭据离开了本机，
/// 与 docs/sync-boundaries.md 里"pin_hash 绝不同步"的承诺相反。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();

  /// v10 的真实表结构（没有同步元数据列）。
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
  late Database db;

  setUp(() async {
    serverRoot = await Directory.systemTemp.createTemp('cs_whitelist_srv');
    deviceRoot = await Directory.systemTemp.createTemp('cs_whitelist_dev');
    serverDb = openServerDb(p.join(serverRoot.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    db = await DatabaseHelper.openIndependent(
      p.join(deviceRoot.path, 'data', 'score.db'),
    );
    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      ['dev_initial'],
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

  Future<SyncClient> pairDevice() async {
    final code = issuePairingCode(serverDb);
    final client = SyncClient(baseUrl: baseUrl, token: '');
    final result = await client.pair(
      code: code,
      deviceId: 'dev_initial',
      deviceName: 'classroom',
    );
    client.close();
    expect(result, isNotNull);
    return SyncClient(baseUrl: baseUrl, token: result!.token);
  }

  test('新建库：快照只带白名单里的设置键', () async {
    // 白名单内
    await db.update('app_settings', {'value': '2'},
        where: 'key = ?', whereArgs: ['current_period']);
    // 白名单外（含安全相关）
    for (final entry in {
      'pin_hash': 'PIN_SECRET_ABC',
      'theme_seed_color': '0xFF6750A4',
      'weather_city': 'Beijing',
      'desktop_bar_opacity': '0.8',
    }.entries) {
      await db.insert('app_settings', {'key': entry.key, 'value': entry.value});
    }

    final events =
        await SyncEventCodec(db).snapshotLocalRows(startRev: 0, deviceId: 'dev_initial');
    final keys = events
        .where((e) => e.table == 'app_settings')
        .map((e) => e.data!['key'] as String)
        .toSet();

    expect(keys, contains('current_period'));
    expect(keys, isNot(contains('pin_hash')), reason: '解锁凭据绝不能离开本机');
    expect(keys, isNot(contains('theme_seed_color')));
    expect(keys, isNot(contains('weather_city')));
    expect(keys, isNot(contains('desktop_bar_opacity')));
  });

  test('整条链路：配对后服务端上查不到 pin_hash', () async {
    await db.update('app_settings', {'value': '2'},
        where: 'key = ?', whereArgs: ['current_period']);
    await db.insert('app_settings', {'key': 'pin_hash', 'value': 'PIN_SECRET_ABC'});
    await db.insert(
        'app_settings', {'key': 'theme_seed_color', 'value': '0xFF6750A4'});

    final client = await pairDevice();
    final events = await SyncEventCodec(db)
        .snapshotLocalRows(startRev: 0, deviceId: 'dev_initial');
    for (var i = 0; i < events.length; i += 200) {
      await client.push(events.sublist(i, (i + 200).clamp(0, events.length)));
    }

    final rows =
        serverDb.select("SELECT payload FROM latest WHERE tbl = 'app_settings'");
    final keys = rows
        .map((r) => (jsonDecode(r['payload'] as String) as Map)['key'])
        .toSet();
    expect(keys, contains('current_period'));
    expect(keys, isNot(contains('pin_hash')), reason: '凭据不能出现在服务端');
    expect(keys, isNot(contains('theme_seed_color')));

    final dumped = rows.map((r) => r['payload']).join('|');
    expect(dumped, isNot(contains('PIN_SECRET_ABC')));
    client.close();
  });

  test('v10 老库升级后：历史设置同样只上传白名单', () async {
    // 用真实的 v10 库覆盖刚才 setUp 建的空库
    await db.close();
    final dbPath = p.join(deviceRoot.path, 'data', 'score.db');
    final file = File(dbPath);
    if (file.existsSync()) file.deleteSync();

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
    await legacy.insert(
        'students', {'name': '张三', 'student_number': '01', 'group_id': gid});
    await legacy.insert('app_settings', {'key': 'current_period', 'value': '2'});
    await legacy.insert(
        'app_settings', {'key': 'pin_hash', 'value': 'PIN_SECRET_ABC'});
    await legacy.insert(
        'app_settings', {'key': 'theme_seed_color', 'value': '0xFF6750A4'});
    await legacy.insert('app_settings', {'key': 'weather_city', 'value': 'Beijing'});
    await legacy.close();

    db = await DatabaseHelper.openIndependent(dbPath);
    await db.rawUpdate(
        "UPDATE sync_state SET value = 'dev_initial' WHERE key = 'device_id'");

    // 迁移给白名单行补了 uid，白名单外的行保持 NULL（多一层保险）
    final settings = await db.query('app_settings');
    String? uidOf(String key) =>
        settings.firstWhere((r) => r['key'] == key)['uid'] as String?;
    expect(uidOf('current_period'), isNotNull);
    expect(uidOf('pin_hash'), isNull, reason: '白名单外的历史行不应获得 uid');

    final events = await SyncEventCodec(db)
        .snapshotLocalRows(startRev: 0, deviceId: 'dev_initial');
    final keys = events
        .where((e) => e.table == 'app_settings')
        .map((e) => e.data!['key'] as String)
        .toSet();
    expect(keys, {'current_period'}, reason: '老库升级后也只能带白名单');
  });
}
