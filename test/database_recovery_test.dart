import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据库健壮性：坏库不该让应用起不来，而是要「留档 → 从备份恢复 → 兜底空库」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('class_score_db_heal');
    DatabaseHelper.dbDirOverride = p.join(root.path, 'data');
    Directory(DatabaseHelper.dbDirOverride!).createSync(recursive: true);
  });

  tearDown(() async {
    await DatabaseHelper.instance.closeDatabase();
    DatabaseHelper.dbDirOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('正常库可以打开，而且设置项读到的是字符串', () async {
    final db = await DatabaseHelper.instance.database;
    await DatabaseHelper.instance.setSetting('demo_key', 'demo_value');
    expect(await DatabaseHelper.instance.getSetting('demo_key'), 'demo_value');
    expect(DatabaseHelper.instance.lastOpenError, isNull);
    await db.close();
  });

  test('设置项的 value 为 NULL 时降级成 null，而不是抛类型错误', () async {
    final db = await DatabaseHelper.instance.database;
    // 新版建表是 value TEXT NOT NULL，但历史库可能没这个约束（或者是被
    // 外部工具改过的库）。这里把表重建成可空来模拟那种现场。
    await db.execute('ALTER TABLE app_settings RENAME TO app_settings_old');
    await db.execute(
      'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT)',
    );
    await db.execute(
      'INSERT INTO app_settings (key, value) SELECT key, value '
      'FROM app_settings_old',
    );
    await db.execute('DROP TABLE app_settings_old');

    await db.insert('app_settings', {'key': 'null_key', 'value': null});
    expect(await DatabaseHelper.instance.getSetting('null_key'), isNull);
  });

  test('库文件被写坏且没有备份时，留档坏库并建出可用的空库', () async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('groups', {'name': '第一组'});
    await db.close();
    await DatabaseHelper.instance.closeDatabase();

    // 把主库写成垃圾（模拟断电 / 磁盘损坏）。文件头不是 SQLite 格式，
    // openDatabase 会在首次读取 schema 时失败。
    final dbFile = File(DatabaseHelper.instance.dbPath);
    dbFile.writeAsStringSync('this is definitely not a sqlite database' * 64);

    final reopened = await DatabaseHelper.instance.database;
    expect(await reopened.query('groups'), isEmpty);
    expect(DatabaseHelper.instance.lastOpenError, isNotNull);

    // 坏库留了档，没有被直接删掉
    final leftovers = Directory(DatabaseHelper.instance.dbDir)
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.broken-'))
        .toList();
    expect(leftovers, isNotEmpty);
  });

  test('库文件被写坏但有备份时，从备份恢复数据', () async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('groups', {'name': '备份里的组'});

    final backupDir = Directory(p.join(root.path, 'backups'));
    backupDir.createSync(recursive: true);
    final snapshot = p.join(backupDir.path, 'backup_demo.db');
    await db.execute('VACUUM INTO ?', [snapshot]);
    await db.close();
    await DatabaseHelper.instance.closeDatabase();

    File(DatabaseHelper.instance.dbPath)
        .writeAsStringSync('broken' * 1024);

    final reopened = await DatabaseHelper.instance.database;
    final rows = await reopened.query('groups');
    expect(rows.map((row) => row['name']).toList(), ['备份里的组']);
    expect(DatabaseHelper.instance.lastOpenError, contains('备份'));
  });
}