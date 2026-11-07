import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 学生学号是**唯一索引**，但唯一性只在一台设备内部成立。
///
/// 两台设备各自离线时给不同学生分配了同一个学号（很常见：两边都从"下一个
/// 空号"开始算），合并时远端那条 INSERT 会撞 UNIQUE(students.student_number)。
/// 这个异常发生在 applyRemote 里，被拉取循环吞掉并计数——数据没进来，
/// 但同步状态看起来是正常的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory a;
  late Directory b;
  late Database dbA;
  late Database dbB;

  Future<Database> openAt(Directory root, String deviceId) async {
    final db = await DatabaseHelper.openIndependent(
      p.join(root.path, 'data', 'score.db'),
    );
    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      [deviceId],
    );
    return db;
  }

  setUp(() async {
    a = await Directory.systemTemp.createTemp('cs_num_a');
    b = await Directory.systemTemp.createTemp('cs_num_b');
    dbA = await openAt(a, 'devA');
    dbB = await openAt(b, 'devB');
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
    for (final dir in [a, b]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('两端离线各加一个"01"号的不同学生，合并后两个人都必须在', () async {
    final gA = await dbA.insert('groups', {'name': '一班'});
    await dbA.insert('students', {
      'name': '张三', 'student_number': '01', 'group_id': gA,
    });
    final gB = await dbB.insert('groups', {'name': '一班'});
    await dbB.insert('students', {
      'name': '李四', 'student_number': '01', 'group_id': gB,
    });

    // 双向合并
    for (final e in await SyncEventCodec(dbA).readOutbox()) {
      await SyncEventCodec(dbB).applyRemote(e);
    }
    for (final e in await SyncEventCodec(dbB).readOutbox()) {
      await SyncEventCodec(dbA).applyRemote(e);
    }

    final onA = await dbA.query('students', where: 'deleted_at IS NULL');
    final onB = await dbB.query('students', where: 'deleted_at IS NULL');
    expect(
      onA.map((s) => s['name']).toSet(),
      {'张三', '李四'},
      reason: '学号冲突不能让任何一个学生丢失',
    );
    expect(
      onB.map((s) => s['name']).toSet(),
      {'张三', '李四'},
    );
  });

  test('撞车的那个学生被改成空号，原有学号保持不变', () async {
    // 本地 dbB 上已经有一个 01 号的张三
    final gB = await dbB.insert('groups', {'name': '一班'});
    await dbB.insert('students', {
      'name': '张三', 'student_number': '01', 'group_id': gB,
    });

    // B 端上 01 已经被占，但这条事件来自另一台设备，且是"02 号"的张三
    await SyncEventCodec(dbB).applyRemote(
      const SyncEvent(
        table: 'students',
        uid: 'stu_conflict',
        op: SyncOp.upsert,
        rev: 99,
        revDevice: 'devC',
        data: {
          'name': '外来的李四',
          'student_number': '01',
          'group_uid': null,
          'include_in_group_total': 1,
        },
      ),
    );

    final rows = await dbB.query('students', where: 'deleted_at IS NULL', orderBy: 'id');
    expect(rows, hasLength(2), reason: '撞号不能丢人');
    expect(rows.first['student_number'], '01');
    expect(rows.first['name'], '张三', reason: '先到的保留原号');
    expect(rows.last['name'], '外来的李四');
    expect(
      rows.last['student_number'],
      isNot('01'),
      reason: '后来者应当被改成一个空号',
    );
  });

  test('同一天的调休：本地较新的版本赢，远端旧版整条丢弃而不是撞唯一索引', () async {
    await dbB.insert('schedule_adjustment', {
      'date': '2026-11-05',
      'weekday': 5,
      'created_at': DateTime.now().toIso8601String(),
    });
    // 把本地这一行的 rev 抬高，明确"本地更新"
    await dbB.rawUpdate(
      "UPDATE schedule_adjustment SET rev = 50 WHERE date = '2026-11-05'",
    );
    final localRow = (await dbB.query('schedule_adjustment')).single;
    expect(localRow['deleted_at'], isNull);
    expect(localRow['rev'], 50);

    final applied = await SyncEventCodec(dbB).applyRemote(
      const SyncEvent(
        table: 'schedule_adjustment',
        uid: 'adj_other_device',
        op: SyncOp.upsert,
        rev: 1,
        revDevice: 'devZ',
        data: {'date': '2026-11-05', 'weekday': 1, 'created_at': '2026-01-01T00:00:00'},
      ),
    );
    expect(applied, isFalse, reason: '本地更新，远端旧版应该被丢弃');
    final rows = await dbB.query('schedule_adjustment');
    expect(rows, hasLength(1), reason: '同一天只能有一条');
    expect(rows.single['weekday'], 5);
  });
}
