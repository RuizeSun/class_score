import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/services/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 退出前的兜底：延后队列里的快照必须能在进程结束前被**立刻**补上。
///
/// 场景：用户刚记完分就点退出。如果那份快照还排在 400ms 的定时器里，
/// `exit(0)` 会把它一起带走——这正是「写完就退出丢备份」的成因。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('backup_flush_test');
    DatabaseHelper.dbDirOverride = tempDir.path;
    BackupService.backupDirOverride =
        '${tempDir.path}${Platform.pathSeparator}backups';
    BackupService.instance.resetForTest();
    await DatabaseHelper.instance.reloadAll();
    final db = await DatabaseHelper.instance.database;
    await db.insert('groups', {'name': '一组'});
  });

  tearDown(() async {
    await DatabaseHelper.instance.closeDatabase();
    DatabaseHelper.dbDirOverride = null;
    BackupService.backupDirOverride = null;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('flushPendingBackup 不等延后时长就落下一份备份', () async {
    BackupService.instance.scheduleBackup();
    expect(BackupService.instance.hasPendingBackup, isTrue);
    expect(await BackupService.instance.listBackups(), isEmpty);

    final flushed = await BackupService.instance.flushPendingBackup();
    expect(flushed, isTrue);
    expect(BackupService.instance.hasPendingBackup, isFalse);
    expect(
      await BackupService.instance.listBackups(),
      isNotEmpty,
      reason: '退出前 flush 必须真的产生备份文件',
    );
  });

  test('没有排队时 flush 是空操作', () async {
    expect(await BackupService.instance.flushPendingBackup(), isFalse);
  });

  test('resetForTest 会撤掉排队中的定时器（避免跨用例假通过）', () async {
    BackupService.instance.scheduleBackup();
    expect(BackupService.instance.hasPendingBackup, isTrue);

    BackupService.instance.resetForTest();
    expect(BackupService.instance.hasPendingBackup, isFalse);

    await Future<void>.delayed(
      BackupService.scheduledDelay + const Duration(milliseconds: 300),
    );
    expect(
      await BackupService.instance.listBackups(),
      isEmpty,
      reason: '被重置掉的定时器不应该再触发备份',
    );
  });
}
