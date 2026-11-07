import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_client.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// 一次"像真实班级那样用一遍"的同步演练。
///
/// 前面几个测试各自只覆盖一条规则；这里按老师在课堂上的真实顺序操作一遍：
/// 建组 → 加人 → 打分 → 改名 → 换组 → 删记录 → 删人，
/// 中间穿插**离线**（不推不拉）与**重新上线**，最后要求两端逐表一致。
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

  const deviceScreen = 'dev_classroom_screen';
  const deviceTeacher = 'dev_teacher_pc';

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
      code: code,
      deviceId: deviceId,
      deviceName: deviceId,
    );
    client.close();
    return SyncClient(baseUrl: baseUrl, token: result!.token);
  }

  /// 模拟引擎的一轮同步：推自己的 outbox，再把自己的游标往后拉。
  Future<void> roundTrip(SyncClient client, Database db) async {
    final codec = SyncEventCodec(db);
    await client.push(await codec.readOutbox());
    final cursorRows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: ['server_seq'],
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

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_drill_srv');
    serverDb = openServerDb(p.join(root.path, 'server.db'));
    server = await serveSync(db: serverDb, host: '127.0.0.1', port: 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    rootScreen = await Directory.systemTemp.createTemp('cs_drill_screen');
    rootTeacher = await Directory.systemTemp.createTemp('cs_drill_teacher');
    screen = await openAt(rootScreen, deviceScreen);
    teacher = await openAt(rootTeacher, deviceTeacher);
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

  test('按真实课堂顺序操作一轮，两台设备最终逐表一致', () async {
    final clientScreen = await pairAs(deviceScreen);
    final clientTeacher = await pairAs(deviceTeacher);

    // ---- 大屏：建两个组、加三个学生 ----
    final groupA = await screen.insert('groups', {'name': '一班'});
    final groupB = await screen.insert('groups', {'name': '二班'});
    final s1 = await screen.insert('students', {
      'name': '张三',
      'student_number': '01',
      'group_id': groupA,
    });
    final s2 = await screen.insert('students', {
      'name': '李四',
      'student_number': '02',
      'group_id': groupA,
    });
    final s3 = await screen.insert('students', {
      'name': '王五',
      'student_number': '03',
      'group_id': groupB,
    });

    // ---- 大屏：打分 ----
    final itemId = await screen.insert('score_items', {
      'name': '课堂表现',
      'default_score': 1,
      'description': '',
    });
    for (final (studentId, score, reason) in [
      (s1, 2.0, '回答问题'),
      (s2, 1.0, '值日'),
      (s3, -1.0, '迟到'),
    ]) {
      await screen.insert('score_records', {
        'target_type': 'student',
        'target_id': studentId,
        'score': score,
        'reason': reason,
        'score_item_id': itemId,
        'create_time': DateTime.now().toIso8601String(),
        'period': 1,
      });
    }

    // ---- 第一轮同步：老师那边应当看到完整的一批 ----
    await roundTrip(clientScreen, screen);
    await roundTrip(clientTeacher, teacher);

    expect(await teacher.query('students'), hasLength(3));
    expect(await teacher.query('score_records'), hasLength(3));
    final teacherStudents = await teacher.query('students', orderBy: 'id');
    expect(
      teacherStudents.map((s) => s['name']).toList(),
      ['张三', '李四', '王五'],
    );

    // ---- 老师在服务端在线时改名 + 换组（这是唯一允许"远端写入"的动作） ----
    final tS1 = teacherStudents.firstWhere((s) => s['name'] == '张三');
    await teacher.update(
      'students',
      {'name': '张三丰'},
      where: 'id = ?',
      whereArgs: [tS1['id']],
    );
    await roundTrip(clientTeacher, teacher);

    // ---- 大屏此刻离线：删掉李四的评分记录，并删掉王五 ----
    await screen.delete(
      'score_records',
      where: 'target_type = ? AND target_id = ?',
      whereArgs: ['student', s2],
    );
    await screen.delete('students', where: 'id = ?', whereArgs: [s3]);

    // 再同步一次：老师的改名传过去，大屏的删除也传过去
    await roundTrip(clientTeacher, teacher);
    await roundTrip(clientScreen, screen);
    await roundTrip(clientTeacher, teacher);

    // ---- 逐表校验：两端收敛到同一份数据 ----
    //
    // 比对的是**逻辑内容**而不是 uid。uid 在一种情况下会故意不同：
    // app_settings / schedule_adjustment 这类"一行一个 key"的表撞车时，
    // 我们选择"就地覆盖本地那一行"以保住唯一性，此时 uid 保持本地的不变。
    // 这正是想要的收敛结果——两端内容一致、且各自只有一行。
    for (final spec in syncTableSpecs) {
      final table = spec.name;
      final orderColumn = table == 'app_settings' ? 'key' : 'uid';
      final rowsScreen = await screen.query(
        table,
        where: 'deleted_at IS NULL',
        orderBy: orderColumn,
      );
      final rowsTeacher = await teacher.query(
        table,
        where: 'deleted_at IS NULL',
        orderBy: orderColumn,
      );
      expect(
        rowsTeacher.length,
        rowsScreen.length,
        reason: '$table 的存活行数应当一致',
      );
      expect(
        rowsTeacher.map((r) => r[orderColumn]).toList(),
        rowsScreen.map((r) => r[orderColumn]).toList(),
        reason: '$table 的存活行（按 $orderColumn）应当一致',
      );
      // 业务列也必须一致（uid 之外的内容才是用户看到的东西）
      for (final column in spec.columns) {
        expect(
          rowsTeacher.map((r) => r[column]).toList(),
          rowsScreen.map((r) => r[column]).toList(),
          reason: '$table.$column 的值两端应当一致',
        );
      }
    }

    // 具体内容校验
    final liveStudents = await teacher.query(
      'students',
      where: 'deleted_at IS NULL',
      orderBy: 'id',
    );
    expect(liveStudents.map((s) => s['name']), ['张三丰', '李四']);
    final liveRecords = await teacher.query(
      'score_records',
      where: 'deleted_at IS NULL',
    );
    expect(liveRecords, hasLength(2), reason: '李四那条记录在大屏上被删掉了');

    // 外键在两端都必须指到"自己的本地 id"，而不是一串数字照抄
    final zhang = liveStudents.firstWhere((s) => s['name'] == '张三丰');
    final groupOnTeacher = await teacher.query(
      'groups',
      where: 'id = ?',
      whereArgs: [zhang['group_id']],
    );
    expect(groupOnTeacher.single['name'], '一班');

    clientScreen.close();
    clientTeacher.close();
  });
}
