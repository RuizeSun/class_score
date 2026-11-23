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

  group('BackupService.restoreBackup', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('class_score_restore');
      DatabaseHelper.dbDirOverride = p.join(root.path, 'data');
      BackupService.backupDirOverride = p.join(root.path, 'backups');
    });

    tearDown(() async {
      await DatabaseHelper.instance.closeDatabase();
      DatabaseHelper.dbDirOverride = null;
      BackupService.backupDirOverride = null;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('恢复会把备份内容写回主库（备份先用完整性检查校验）', () async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('groups', {'name': '备份前'});
      final backup = await BackupService.instance.createBackup(force: true);
      expect(backup, isNotNull);

      await db.insert('groups', {'name': '备份后新增'});
      expect((await db.query('groups')).length, 2);

      expect(await BackupService.instance.restoreBackup(backup!), isTrue);
      final reopened = await DatabaseHelper.instance.database;
      final names = (await reopened.query('groups'))
          .map((row) => row['name'])
          .toList();
      expect(names, ['备份前']);
    });

    test('备份文件不是数据库时拒绝恢复，原数据不受影响', () async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('groups', {'name': '原数据'});

      final dir = BackupService.backupDirOverride!;
      Directory(dir).createSync(recursive: true);
      final fake = p.join(dir, 'broken.db');
      File(fake).writeAsStringSync('not a database at all' * 32);

      expect(await BackupService.instance.restoreBackup(fake), isFalse);
      final names = (await db.query('groups'))
          .map((row) => row['name'])
          .toList();
      expect(names, ['原数据']);
    });
  });

  group('BackupService.importFromJson', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('class_score_import');
      DatabaseHelper.dbDirOverride = p.join(root.path, 'data');
      BackupService.backupDirOverride = p.join(root.path, 'backups');
    });

    tearDown(() async {
      await DatabaseHelper.instance.closeDatabase();
      DatabaseHelper.dbDirOverride = null;
      BackupService.backupDirOverride = null;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('导入中途失败不会把已有数据清空（整段在一个事务里）', () async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('groups', {'name': '原有组'});

      // students 缺 group_id 这类必填列：插入会失败，整个事务应当回滚。
      const broken =
          '{"groups": [{"name": "新组"}], "students": [{"name": "坏学生"}]}';
      expect(await BackupService.instance.importFromJson(broken), isFalse);

      final names = (await db.query('groups'))
          .map((row) => row['name'])
          .toList();
      expect(names, ['原有组']);
    });

    test('合法快照能完整导入', () async {
      const good =
          '{"groups": [{"id": 1, "name": "导入组"}], '
          '"students": [{"id": 1, "name": "张三", "student_number": "01", "group_id": 1}]}';
      expect(await BackupService.instance.importFromJson(good), isTrue);

      final db = await DatabaseHelper.instance.database;
      expect((await db.query('groups')).map((r) => r['name']), ['导入组']);
      expect((await db.query('students')).map((r) => r['name']), ['张三']);
    });
  });
}
