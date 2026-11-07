import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/sync/sync_event_codec.dart';
import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 评分记录的多态外键：`target_type` 存的是单数（student / group），
/// 而表名是复数（students / groups）。
///
/// 这里曾经直接把 target_type 当表名拿去查 uid，结果是**所有评分记录都推不出去**
/// （no such table: student），而学生、小组照样同步——界面上看起来"同步是好的"，
/// 只是分数都不见了。这是最隐蔽的一类缺陷，必须逐字段钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory rootA;
  late Directory rootB;
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
    rootA = await Directory.systemTemp.createTemp('cs_poly_a');
    rootB = await Directory.systemTemp.createTemp('cs_poly_b');
    dbA = await openAt(rootA, 'devA');
    dbB = await openAt(rootB, 'devB');
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
    for (final dir in [rootA, rootB]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('target_type 映射到正确的表：学生记录的 target_uid 指向学生', () async {
    final groupId = await dbA.insert('groups', {'name': '一班'});
    final studentId = await dbA.insert('students', {
      'name': '张三',
      'student_number': '01',
      'group_id': groupId,
    });
    final studentRow =
        (await dbA.query('students', where: 'id = ?', whereArgs: [studentId]))
            .single;
    await dbA.insert('score_records', {
      'target_type': 'student',
      'target_id': studentId,
      'score': 2,
      'create_time': DateTime.now().toIso8601String(),
      'period': 1,
    });

    final events = await SyncEventCodec(dbA).readOutbox();
    final recordEvent = events.firstWhere((e) => e.table == 'score_records');
    expect(
      recordEvent.data![scoreRecordTargetUidKey],
      studentRow['uid'],
      reason: 'target_type=student 必须翻译成 students 表的 uid',
    );
    expect(recordEvent.data!.containsKey(scoreRecordTargetColumn), isFalse);
  });

  test('target_type=group 的记录指向小组', () async {
    final groupId = await dbA.insert('groups', {'name': '一班'});
    final groupRow =
        (await dbA.query('groups', where: 'id = ?', whereArgs: [groupId])).single;
    await dbA.insert('score_records', {
      'target_type': 'group',
      'target_id': groupId,
      'score': 5,
      'create_time': DateTime.now().toIso8601String(),
      'period': 1,
    });

    final events = await SyncEventCodec(dbA).readOutbox();
    final recordEvent = events.firstWhere((e) => e.table == 'score_records');
    expect(recordEvent.data![scoreRecordTargetUidKey], groupRow['uid']);
  });

  test('评分记录经 outbox → 对端还原后，target_id 指向对端自己的学生行', () async {
    final groupId = await dbA.insert('groups', {'name': '一班'});
    final studentId = await dbA.insert('students', {
      'name': '张三',
      'student_number': '01',
      'group_id': groupId,
    });
    await dbA.insert('score_records', {
      'target_type': 'student',
      'target_id': studentId,
      'score': 2,
      'reason': '回答问题',
      'create_time': DateTime.now().toIso8601String(),
      'period': 1,
    });

    final codecB = SyncEventCodec(dbB);
    for (final event in await SyncEventCodec(dbA).readOutbox()) {
      await codecB.applyRemote(event);
    }

    final records = await dbB.query('score_records');
    expect(records, hasLength(1));
    final studentsOnB = await dbB.query('students');
    expect(studentsOnB, hasLength(1));
    expect(
      records.single[scoreRecordTargetColumn],
      studentsOnB.single['id'],
      reason: '对端必须映射到它自己的本地学生 id',
    );
    expect(records.single['score'], 2.0);
  });

  test('未知 target_type 不炸：目标是 NOT NULL，用 0 兜底而不是写 null', () async {
    final codecB = SyncEventCodec(dbB);
    final applied = await codecB.applyRemote(
      const SyncEvent(
        table: 'score_records',
        uid: 'rec_odd',
        op: SyncOp.upsert,
        rev: 5,
        revDevice: 'devA',
        data: {
          'target_type': 'unknown_kind',
          'target_uid': 'whatever',
          'score': 1,
          'create_time': '2026-01-01T00:00:00',
          'period': 1,
        },
      ),
    );
    // 关键断言：不能抛异常。applyRemote 一旦抛出，拉取循环中断、游标不前进，
    // 下一轮还会拿到同一条事件 —— 同步会永久卡在它上面。
    expect(applied, isTrue);
    final record = (await dbB.query('score_records')).single;
    expect(
      record[scoreRecordTargetColumn],
      0,
      reason: 'target_id 是 NOT NULL，用 0 表示"不指向任何行"',
    );
  });
}
