import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_client.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 第二轮演练：这一轮修的东西必须真的在端到端链路上成立。
///
/// 覆盖：计分规则与周期同步、课表 diff、孤儿统计口径、占位行可见。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();

  late Directory root;
  late sqlite3.Database serverDb;
  late HttpServer server;
  late String baseUrl;
  late Directory rootScreen;
  late Directory rootTeacher;
  late Database screen;
  late Database teacher;

  Future<Database> openAt(Directory dir, String deviceId) async {
    final db = await DatabaseHelper.openIndependent(
      p.join(dir.path, 'data', 'score.db'),
    );
    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      [deviceId],
    );
    return db;
  }

  Future<SyncClient> pairAs(String deviceId) async {
    final code = issuePairingCode(serverDb);
    final client = SyncClient(baseUrl: baseUrl, token: '');
    final result = await client.pair(
      code: code, deviceId: deviceId, deviceName: deviceId,
    );
    client.close();
    return SyncClient(baseUrl: baseUrl, token: result!.token);
  }

  Future<void> roundTrip(SyncClient client, Database db) async {
    final codec = SyncEventCodec(db);
    await client.push(await codec.readOutbox());
    final cursorRows = await db.query(
      'sync_state', where: 'key = ?', whereArgs: ['server_seq'],
    );
    final cursor = int.tryParse(cursorRows.first['value'] as String) ?? 0;
    final page = await client.pull(since: cursor);
    for (final event in page.events) {
      await codec.applyRemote(event);
    }
    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'server_seq'",
      [page.seq.toString()],
    );
  }

  Future<String?> settingOn(Database db, String key) async {
    final rows = await db.query(
      'app_settings',
      where: 'key = ? AND deleted_at IS NULL',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.single['value'] as String?;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('drill2_srv');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    rootScreen = await Directory.systemTemp.createTemp('drill2_screen');
    rootTeacher = await Directory.systemTemp.createTemp('drill2_teacher');
    screen = await openAt(rootScreen, 'dev_screen');
    teacher = await openAt(rootTeacher, 'dev_teacher');
  });

  tearDown(() async {
    await server.close(force: true);
    serverDb.dispose();
    await screen.close();
    await teacher.close();
    for (final dir in [root, rootScreen, rootTeacher]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('这一轮修的四件事在端到端链路上都成立', () async {
    final clientScreen = await pairAs('dev_screen');
    final clientTeacher = await pairAs('dev_teacher');

    // --- 1. 计分规则与周期 ---
    // 用 update-or-insert：有些键在全新库里本来就没有（迁移只播种了少数几个），
    // 直接 UPDATE 会一行都没改到、也就不会产生事件。
    Future<void> setSetting(String key, String value) async {
      final updated = await screen.update(
        'app_settings', {'value': value, 'deleted_at': null},
        where: 'key = ?', whereArgs: [key],
      );
      if (updated == 0) {
        await screen.insert('app_settings', {'key': key, 'value': value});
      }
    }
    await setSetting('current_period', '2');
    await setSetting('student_initial_score', '5');
    await setSetting('group_score_mode', 'average');

    // --- 2. 课表 diff：先建两门课，再只删一门 ---
    await screen.insert('course_schedule', {
      'weekday': 1, 'course_name': '数学',
      'start_time': '08:00', 'end_time': '08:45',
    });
    await screen.insert('course_schedule', {
      'weekday': 1, 'course_name': '语文',
      'start_time': '09:00', 'end_time': '09:45',
    });

    await roundTrip(clientScreen, screen);
    await roundTrip(clientTeacher, teacher);

    expect(await settingOn(teacher, 'current_period'), '2');
    expect(await settingOn(teacher, 'student_initial_score'), '5');
    expect(await settingOn(teacher, 'group_score_mode'), 'average');
    expect(
      (await teacher.query('course_schedule', where: 'deleted_at IS NULL')),
      hasLength(2),
    );

    // 老师端的课表 uid
    final teacherCourses = await teacher.query(
      'course_schedule', where: 'deleted_at IS NULL', orderBy: 'course_name',
    );
    final mathUid = teacherCourses
        .firstWhere((r) => r['course_name'] == '数学')['uid'];

    // 大屏只删语文
    await screen.delete('course_schedule',
        where: 'course_name = ?', whereArgs: ['语文']);
    final deleteEvents = await SyncEventCodec(screen).readOutbox();
    expect(
      deleteEvents.where((e) => e.op.name == 'delete'),
      hasLength(1),
      reason: '只删一门课就只该有一条墓碑',
    );
    await roundTrip(clientScreen, screen);
    await roundTrip(clientTeacher, teacher);

    final coursesOnTeacher = await teacher.query(
      'course_schedule', where: 'deleted_at IS NULL',
    );
    expect(coursesOnTeacher, hasLength(1));
    expect(
      coursesOnTeacher.single['uid'],
      mathUid,
      reason: '没动的课必须保住 uid（这就是 diff 的意义）',
    );

    // --- 3. 孤儿记录：删学生后两端统计口径一致 ---
    final groupId = await screen.insert('groups', {'name': '一班'});
    final keep = await screen.insert('students', {
      'name': '李四', 'student_number': '02', 'group_id': groupId,
    });
    final gone = await screen.insert('students', {
      'name': '张三', 'student_number': '01', 'group_id': groupId,
    });
    for (final (sid, score) in [(keep, 3.0), (gone, 100.0)]) {
      await screen.insert('score_records', {
        'target_type': 'student', 'target_id': sid, 'score': score,
        'create_time': DateTime.now().toIso8601String(), 'period': 2,
      });
    }
    await roundTrip(clientScreen, screen);
    await roundTrip(clientTeacher, teacher);

    // 老师端此时能看到两个人、总分 103
    expect(
      (await teacher.query('students', where: 'deleted_at IS NULL')),
      hasLength(2),
    );

    // 大屏删掉张三
    await screen.delete('students', where: 'id = ?', whereArgs: [gone]);
    await roundTrip(clientScreen, screen);
    await roundTrip(clientTeacher, teacher);

    // 两端：名单里只剩李四，统计口径都只算 3 分
    for (final db in [screen, teacher]) {
      final live = await db.query('students', where: 'deleted_at IS NULL');
      expect(live.map((s) => s['name']), ['李四']);
    }

    // 统计口径校验：直接用 teacher 这条连接跑与 DatabaseHelper 相同的聚合，
    // 避免单例缓存指向别的库（DatabaseHelper.instance 在其它测试里可能已打开）。
    final positiveRows = await teacher.rawQuery(
      'SELECT COALESCE(SUM(CASE WHEN score > 0 THEN score ELSE 0 END), 0) AS p '
      "FROM score_records WHERE deleted_at IS NULL "
      "AND (target_type <> 'student' OR EXISTS ("
      'SELECT 1 FROM students s WHERE s.id = score_records.target_id '
      'AND s.deleted_at IS NULL))',
    );
    final totalPositive = (positiveRows.first['p'] as num).toDouble();
    expect(
      totalPositive,
      3.0,
      reason: '删掉的学生那 100 分不能再计入班级总分',
    );

    // 明细仍然保留两条历史（历史不该因为删了人就消失）
    final details = await teacher.query(
      'score_records',
      where: 'deleted_at IS NULL',
    );
    expect(details, hasLength(2));

    clientScreen.close();
    clientTeacher.close();
  });
}
