import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/services/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `scheduleBackup` 是「不阻塞提交」的关键：它把整库快照推到下一帧之后再跑。
/// 这里钉死三件事：
/// 1. 调用后**立刻返回**（不 await 备份）；
/// 2. 延后时长过后确实产生了一份备份；
/// 3. `createBackup(force: true)` 仍然是同步语义（破坏性操作先有备份）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('backup_schedule_test');
    DatabaseHelper.dbDirOverride = tempDir.path;
    BackupService.backupDirOverride = '${tempDir.path}${Platform.pathSeparator}backups';
    // 单例跨用例保留状态：清掉「上次备份时刻」与被节流标记。
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

  test('scheduleBackup 立即返回，不等待备份完成', () async {
    final stopwatch = Stopwatch()..start();
    BackupService.instance.scheduleBackup();
    stopwatch.stop();

    // 排进延后队列就返回：不应等整库快照（VACUUM INTO）跑完。
    expect(stopwatch.elapsedMilliseconds, lessThan(50));
    // 排队期间不再重复排队（不返回值，只能验证「确实还没备份」）。
    final filesBefore = await BackupService.instance.listBackups();
    expect(filesBefore, isEmpty);
  });

  test('延后时长过后备份文件真的出现', () async {
    BackupService.instance.scheduleBackup();

    // 等待「下一帧 + scheduledDelay」落下，再给快照本身留出余量。
    await Future<void>.delayed(
      BackupService.scheduledDelay + const Duration(milliseconds: 800),
    );

    final files = await BackupService.instance.listBackups();
    expect(files, isNotEmpty, reason: '延后队列应真正执行了一次备份');
  });

  test('force 备份是同步语义：调用返回时文件已存在', () async {
    final path = await BackupService.instance.createBackup(force: true);
    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);
  });
}
