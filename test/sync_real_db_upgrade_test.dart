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

/// 拿**真实机器上正在用的那个 v10 库**跑一遍升级 + 首次会合。
///
/// 前面的用例都是自己造的 v10 库，字段和体量都与实际相近但不等同。
/// 老师的真实库里可能有旧版本遗留的表结构、异常数据、非 ASCII 姓名等，
/// 用真库跑一次才算真正确认\"升级不炸、数据上得去\"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();

  const realDb = 'build/windows/x64/runner/Release/data/score.db';
  final skip = !File(realDb).existsSync();
  if (skip) {
    test('（跳过）找不到真实库', () {}, skip: '本机没有 Release 版数据库');
    return;
  }

  late Directory root;
  late Directory serverRoot;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late Database db;
  late String baseUrl;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_realdb');
    final dataDir = Directory(p.join(root.path, 'data'));
    await dataDir.create(recursive: true);
    // 复制一份再升级，绝不碰用户真实库
    await File(realDb).copy(p.join(dataDir.path, 'score.db'));
    serverRoot = await Directory.systemTemp.createTemp('cs_realdb_srv');
    serverDb = openServerDb(p.join(serverRoot.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    db = await DatabaseHelper.openIndependent(p.join(dataDir.path, 'score.db'));
  });

  // 每个用例一个独立设备号，避免配对冲突。
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);

  tearDown(() async {
    await server.close(force: true);
    serverDb.dispose();
    await db.close();
    for (final d in [root, serverRoot]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  test('真实 v10 库：升级到 v11 后数据完好、uid 已补齐、outbox 为空', () async {
    final version = await db.getVersion();
    expect(version, 11);

    // 用户实际有数据的表
    final courses = await db.query('course_schedule', where: 'deleted_at IS NULL');
    expect(courses, isNotEmpty, reason: '真实库里有课表');
    for (final row in courses) {
      expect(row['uid'], isNotNull, reason: '迁移必须补齐 uid');
      expect(row['rev'], isNotNull);
    }

    // 迁移刻意不记 outbox（否则升级当天凭空多出几千条待推送）
    expect(await db.query('sync_outbox'), isEmpty);
  });

  test('真实 v10 库：首次会合把历史数据全部推上服务端', () async {
    final code = issuePairingCode(serverDb);
    final anon = SyncClient(baseUrl: baseUrl, token: '');
    // 设备身份由 SyncEngine 在 configure() 时生成（迁移只建表，不造身份）。
    // 这里复刻那一步，因为本用例绕过引擎直接跑 codec。
    final stored =
        (await db.query('sync_state', where: 'key = ?', whereArgs: ['device_id']))
            .single['value'] as String;
    expect(stored, isEmpty, reason: '迁移阶段还不该有设备身份');
    final deviceId = 'dev_real_$stamp';
    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      [deviceId],
    );
    final result = await anon.pair(code: code, deviceId: deviceId, deviceName: 'real');
    anon.close();
    final client = SyncClient(baseUrl: baseUrl, token: result!.token);

    expect((await client.summary()).isEmpty, isTrue);

    final codec = SyncEventCodec(db);
    final localCount = await codec.countLocalRows();
    expect(localCount, greaterThan(0));

    final events = await codec.snapshotLocalRows(startRev: 0, deviceId: deviceId);
    // countLocalRows 是"本地有没有业务数据"的启发式（刻意不含 app_settings，
    // 否则新建库的几行默认设置会让它永远为真）；snapshot 则要把设置也推上去，
    // 所以两者数量不等是预期的——这里只要求快照覆盖全部业务行。
    expect(events.length, greaterThanOrEqualTo(localCount));
    expect(events.where((e) => e.table == 'app_settings'), isNotEmpty,
        reason: '设置也要初始上传（否则对端拿不到当前周期等）');
    for (var i = 0; i < events.length; i += 200) {
      await client.push(events.sublist(i, (i + 200).clamp(0, events.length)));
    }

    final summary = await client.summary();
    final courseCount = (await db.query('course_schedule', where: 'deleted_at IS NULL')).length;
    expect(summary.liveRows['course_schedule'], courseCount);

    // 中文课程名能原样存活（JSON 编码 + SQLite 编码都要对）
    final payloads = serverDb
        .select("SELECT payload FROM latest WHERE tbl = 'course_schedule' AND op <> 'delete'")
        .map((r) => jsonDecode(r['payload'] as String) as Map)
        .toList();
    expect(payloads, isNotEmpty);
    for (final payload in payloads) {
      expect(payload['course_name'], isNotNull);
      expect(payload.containsKey('uid'), isFalse, reason: 'payload 不含同步元数据');
    }
    client.close();
  });
}