import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/services/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('BackupThrottle', () {
    test('首次调用必定备份', () {
      var now = DateTime(2026, 1, 1, 8);
      final throttle = BackupThrottle(
        minInterval: const Duration(minutes: 3),
        clock: () => now,
      );

      expect(throttle.shouldRun(), isTrue);
      throttle.markRun();
      expect(throttle.shouldRun(), isFalse);
    });

    test('超过最短间隔后重新允许备份', () {
      var now = DateTime(2026, 1, 1, 8);
      final throttle = BackupThrottle(
        minInterval: const Duration(minutes: 3),
        clock: () => now,
      );
      throttle.markRun();

      now = now.add(const Duration(minutes: 2, seconds: 59));
      expect(throttle.shouldRun(), isFalse);

      now = now.add(const Duration(seconds: 1));
      expect(throttle.shouldRun(), isTrue);
    });

    test('force 不受间隔限制（用户显式操作 / 整库级破坏性操作）', () {
      var now = DateTime(2026, 1, 1, 8);
      final throttle = BackupThrottle(
        minInterval: const Duration(minutes: 3),
        clock: () => now,
      );
      throttle.markRun();

      expect(throttle.shouldRun(force: true), isTrue);
      expect(throttle.shouldRun(), isFalse);
    });
  });

  group('BackupService.createBackup', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('class_score_backup');
      DatabaseHelper.dbDirOverride = p.join(root.path, 'data');
      BackupService.backupDirOverride = p.join(root.path, 'backups');
    });

    tearDown(() async {
      await DatabaseHelper.instance.closeDatabase();
      DatabaseHelper.dbDirOverride = null;
      BackupService.backupDirOverride = null;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('备份是可用的一致性快照，且不关库、第二次调用被节流跳过', () async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('groups', {'name': '第一组'});

      final first = await BackupService.instance.createBackup(force: true);
      expect(first, isNotNull);
      expect(File(first!).existsSync(), isTrue);

      // 备份没有关掉库：紧接着仍可正常读写
      await db.insert('groups', {'name': '第二组'});
      expect((await db.query('groups')).length, 2);

      // 备份文件本身是完整可读的库，且内容是备份那一刻的数据
      final snapshot = await databaseFactoryFfi.openDatabase(first);
      addTearDown(snapshot.close);
      final copied = await snapshot.query('groups');
      expect(copied.map((row) => row['name']).toList(), ['第一组']);

      // 节流窗口内的自动备份直接跳过，不产生新文件
      expect(await BackupService.instance.createBackup(), isNull);
      final files = Directory(BackupService.backupDirOverride!)
          .listSync()
          .whereType<File>()
          .toList();
      expect(files.length, 1);
    });
  });
}
