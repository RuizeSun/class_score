import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;

import 'sync_migration_v11.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._();
  DatabaseHelper._();

  /// 孤儿评分记录过滤：目标学生/小组已被删（墓碑）时不计入统计。
  ///
  /// v11 把删除改成墓碑之后，`ON DELETE CASCADE` 不再触发：删掉学生，
  /// 他名下的评分记录仍然留在表里，`target_id` 指向一条墓碑行。
  /// 如果这些记录继续参与统计，就会出现"名单里已经没有这个人，
  /// 班级总分里却还算着他的分"。
  ///
  /// **只用于统计口径**（总分、分布、日均）。明细列表（评分变动记录）
  /// 不过滤——历史不该因为删了人就凭空消失。
  static const String orphanRecordFilter =
      "(score_records.target_type <> 'student' OR EXISTS "
      '(SELECT 1 FROM students s WHERE s.id = score_records.target_id '
      'AND s.deleted_at IS NULL))';

  /// 小组维度的孤儿过滤（target_type = 'group' 的那一半）。
  static const String orphanGroupRecordFilter =
      "(score_records.target_type <> 'group' OR EXISTS "
      '(SELECT 1 FROM groups g WHERE g.id = score_records.target_id '
      'AND g.deleted_at IS NULL))';

  Database? _database;

  /// 数据库目录覆盖（测试用）。
  ///
  /// 默认目录取自 `Platform.resolvedExecutable`（exe 同级的 `data/`）；在
  /// `flutter test` 下那是 flutter_tester 所在目录，测试若不覆盖就会把库写到
  /// Flutter SDK 目录里，因此留出这个注入点。
  @visibleForTesting
  static String? dbDirOverride;

  String get dbDir {
    final override = dbDirOverride;
    if (override != null) return override;
    final exePath = Platform.resolvedExecutable;
    final exeDir = p.dirname(exePath);
    return p.join(exeDir, 'data');
  }

  String get dbPath => p.join(dbDir, 'score.db');

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dir = Directory(dbDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    sqfliteFfiInit();
    return _open(dbPath);
  }

  Future<Database> _open(String path) async {
    // 备份必须在 openDatabase **之前**做完。
    //
    // 原先它在 _onUpgrade 里调 `VACUUM INTO`，而 sqflite 把 onUpgrade 包在
    // 事务里，VACUUM 不能在事务内执行 —— 实测每次都抛
    // "cannot VACUUM from within a transaction"，异常被 catch 掉、
    // 只留一行 debugPrint，于是这道安全网**从来没有生效过**，
    // 而所有测试都是绿的（因为没人断言过备份文件存在）。
    await _snapshotBeforeUpgrade(path);
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 11,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  /// 如果要升级就先把整库复制一份。
  ///
  /// 判断版本用**只读打开 + getVersion**，不触发迁移；确认 oldVersion < 11
  /// 之后再做文件级复制（复制不需要 SQL 事务，也就不受 onUpgrade 的包围限制）。
  Future<void> _snapshotBeforeUpgrade(String path) async {
    final file = File(path);
    if (!await file.exists()) return; // 新库，没什么可备份的
    int version;
    try {
      final probe = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      version = await probe.getVersion();
      await probe.close();
    } catch (error) {
      debugPrint('读取数据库版本失败，跳过迁移前备份：$error');
      return;
    }
    if (version >= 11) return;
    await _backupBeforeSyncMigration(file, version);
  }

  /// 测试用：按路径打开一条**独立连接**，不经过单例。
  ///
  /// 双设备同步测试需要同时持有两个库，而单例只能缓存一个连接；
  /// 这里复用同一套 onCreate/onUpgrade，保证结构完全一致。
  @visibleForTesting
  static Future<Database> openIndependent(String path) async {
    sqfliteFfiInit();
    final dir = Directory(p.dirname(path));
    if (!await dir.exists()) await dir.create(recursive: true);
    return DatabaseHelper.instance._open(path);
  }

  /// v11 迁移前的安全网：文件级复制。
  ///
  /// 为什么不是 `VACUUM INTO`：那个必须在一个活动连接上跑，而本方法在
  /// `openDatabase` 之前调用（原因见 [_open] 的注释）。此刻库没有任何连接，
  /// 直接复制文件既等价又简单。
  ///
  /// 失败不阻塞迁移——快照只是多一层保险，迁移本身还有外层事务。
  Future<void> _backupBeforeSyncMigration(File source, int fromVersion) async {
    try {
      // 目录要从**被打开的库**推出来，不能用单例的 dbDir：
      // openIndependent() 会打开任意路径的库，用单例会把它备份到 exe 同级
      // 目录去（测试里就是 Flutter SDK 安装目录，留下一堆垃圾）。
      final sinkDir = Directory(p.join(p.dirname(source.path), '..', 'backups'));
      if (!await sinkDir.exists()) {
        await sinkDir.create(recursive: true);
      }
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final target = p.join(
        sinkDir.path,
        'pre_v11_from_v${fromVersion}_$stamp.db',
      );
      await source.copy(target);
      debugPrint('v11 迁移前已备份到 $target');
    } catch (error) {
      debugPrint('v11 迁移前备份失败（继续迁移）：$error');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE groups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE students (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        student_number TEXT NOT NULL DEFAULT '',
        group_id INTEGER NOT NULL,
        FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_student_number ON students(student_number)',
    );
    await db.execute('''
      CREATE TABLE score_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        target_type TEXT NOT NULL,
        target_id INTEGER NOT NULL,
        score REAL NOT NULL,
        reason TEXT,
        score_item_id INTEGER,
        custom_name TEXT,
        create_time TEXT NOT NULL,
        period INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await _createV2Tables(db);
    await _createV3Tables(db);
    await _createV4Tables(db);
    await _createV5Tables(db);
    await _createV6Tables(db);
    await _createV7Tables(db);
    await _createV8Tables(db);
    await _createV9Tables(db);
    await _createV10Tables(db);
    // v11：同步元数据 + outbox 捕获触发器（见 docs/sync-schema-v11.md）
    await SyncMigrationV11.run(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createV2Tables(db);
    }
    if (oldVersion < 3) {
      await _createV3Tables(db);
    }
    if (oldVersion < 4) {
      await _createV4Tables(db);
      // Add new columns to score_records
      try {
        await db.execute(
          'ALTER TABLE score_records ADD COLUMN score_item_id INTEGER',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE score_records ADD COLUMN custom_name TEXT',
        );
      } catch (_) {}
    }
    if (oldVersion < 5) {
      await _createV5Tables(db);
    }
    if (oldVersion < 6) {
      await _createV6Tables(db);
    }
    if (oldVersion < 7) {
      await _createV7Tables(db);
    }
    if (oldVersion < 8) {
      await _createV8Tables(db);
    }
    if (oldVersion < 9) {
      await _createV9Tables(db);
    }
    if (oldVersion < 10) {
      await _createV10Tables(db);
    }
    if (oldVersion < 11) {
      // 整库快照在 _open 里、**打开连接之前**就做完了（见那里的注释：
      // VACUUM 不能跑在 onUpgrade 的事务里，旧实现因此从来没成功过）。
      await SyncMigrationV11.run(db);
    }
  }

  Future<void> _createV6Tables(Database db) async {
    // 为 score_records 表添加 period 字段
    try {
      await db.execute(
        'ALTER TABLE score_records ADD COLUMN period INTEGER NOT NULL DEFAULT 1',
      );
    } catch (_) {}
    // 为已有的记录设置 period = 1（这些是旧数据）
    try {
      await db.execute(
        'UPDATE score_records SET period = 1 WHERE period IS NULL',
      );
    } catch (_) {}
    // 初始化默认周期设置为 1
    try {
      await db.insert('app_settings', {
        'key': 'current_period',
        'value': '1',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  Future<void> _createV7Tables(Database db) async {
    // 为 score_records 表添加 is_quick 字段，用于标识快速评分产生的记录
    try {
      await db.execute(
        'ALTER TABLE score_records ADD COLUMN is_quick INTEGER NOT NULL DEFAULT 0',
      );
    } catch (_) {}
  }

  Future<void> _createV8Tables(Database db) async {
    // 回收站：保存被删除的评分记录，供“恢复/永久删除/7天后自动清理”
    await db.execute('''
      CREATE TABLE IF NOT EXISTS score_record_archives (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL,
        target_type TEXT NOT NULL,
        target_id INTEGER NOT NULL,
        score REAL NOT NULL,
        reason TEXT,
        score_item_id INTEGER,
        custom_name TEXT,
        create_time TEXT NOT NULL,
        period INTEGER NOT NULL DEFAULT 1,
        is_quick INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT NOT NULL
      )
    ''');
    // 单条评分记录的修改历史（新增/补充变动原因/修改/删除）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS score_record_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL,
        action_type TEXT NOT NULL,
        field TEXT,
        old_value TEXT,
        new_value TEXT,
        content TEXT,
        log_time TEXT NOT NULL
      )
    ''');
    try {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_score_record_logs_record_id ON score_record_logs(record_id)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_score_record_archives_deleted_at ON score_record_archives(deleted_at)',
      );
    } catch (_) {}
  }

  Future<void> _createV9Tables(Database db) async {
    // 学生是否参与其小组总分统计：1 参与（默认），0 不参与
    try {
      await db.execute(
        'ALTER TABLE students ADD COLUMN include_in_group_total INTEGER NOT NULL DEFAULT 1',
      );
    } catch (_) {}
  }

  Future<void> _createV10Tables(Database db) async {
    // 调休：把某个日期临时切换成课表中另一天的课程安排（weekday = 0 表示当天无课）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS schedule_adjustment (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT NOT NULL UNIQUE,
        weekday INTEGER NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    try {
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_schedule_adjustment_date ON schedule_adjustment(date)',
      );
    } catch (_) {}
  }

  Future<void> _createV2Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS usb_keys (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        token TEXT NOT NULL,
        label TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
      ''');
  }

  Future<void> _createV5Tables(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE students ADD COLUMN student_number TEXT NOT NULL DEFAULT \'\'',
      );
    } catch (_) {}
    try {
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_student_number ON students(student_number)',
      );
    } catch (_) {}
  }

  Future<void> _createV3Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS course_schedule (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        weekday INTEGER NOT NULL,
        course_name TEXT NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createV4Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS score_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        default_score REAL NOT NULL,
        description TEXT NOT NULL
      )
    ''');
  }

  Future<void> closeDatabase() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  /// Reload all data after restore/reset - triggers lazy re-initialization
  Future<Database> reloadAll() async {
    await closeDatabase();
    return database;
  }

  // ---- Settings ----
  Future<String?> getSetting(String key) async {
    final db = await database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (result.isNotEmpty) {
      return result.first['value'] as String;
    }
    return null;
  }

  /// 写一个设置项。
  ///
  /// **不能**用 `INSERT OR REPLACE`：SQLite 里它是"先删后插"，而 v11 之后
  /// 删除会变墓碑，新插入的行会拿到一个**全新的 uid** —— 对同步而言等于
  /// "这一行被换成了另一个对象"。两端各改一次同一个键时，LWW 再也收敛不到
  /// 同一个值（各自持有不同 uid，谁也覆盖不了谁）。
  ///
  /// 实测：连改 3 次 `current_period` 产生 3 条不同 uid 的事件。
  ///
  /// 正确做法是"有就 UPDATE、没有才 INSERT"，uid 原地保留。
  /// 墓碑行也要复活（`deleted_at = null`），否则设置会"改了没反应"。
  Future<void> setSetting(String key, String value) async {
    final db = await database;
    final updated = await db.update(
      'app_settings',
      {'value': value, 'deleted_at': null},
      where: 'key = ?',
      whereArgs: [key],
    );
    if (updated > 0) return;
    await db.insert('app_settings', {'key': key, 'value': value});
  }

  // ---- Score Config ----
  /// 读取计分规则全局设置（学生初始分、小组初始分、小组总分计算方式）
  Future<({double studentInitial, double groupInitial, String mode})>
      _getScoreConfig() async {
    final studentInitial =
        double.tryParse((await getSetting('student_initial_score')) ?? '') ??
        0.0;
    final groupInitial =
        double.tryParse((await getSetting('group_initial_score')) ?? '') ??
        0.0;
    final mode = await getSetting('group_score_mode') ?? 'sum';
    return (
      studentInitial: studentInitial,
      groupInitial: groupInitial,
      mode: mode,
    );
  }

  /// 根据小组总分计算方式生成 SQL 表达式（针对已按小组聚合的子查询 m）
  /// m.member_count：小组人数（含不参与小组总分的学生，仅用于展示）；
  /// m.scoring_member_count：参与小组总分统计的人数（总分与人均只按这部分人算）；
  /// m.score_sum：参与统计的成员当期积分变动总和。
  String _groupTotalExpr({
    required ({double studentInitial, double groupInitial, String mode})
        config,
  }) {
    final si = config.studentInitial;
    final gi = config.groupInitial;
    // 公式中的「人数」只统计参与小组总分的学生：不参与的学生既不贡献分值，
    // 也不影响「人均得分」的分母与「学生得分总和」的初始分累加。
    final mc = 'COALESCE(m.scoring_member_count, 0)';
    final ss = 'COALESCE(m.score_sum, 0)';
    switch (config.mode) {
      case 'group_init':
        // 小组自定初始分：小组总分 = 小组初始分 + 成员当期积分变动总和
        return '$ss + $gi';
      case 'avg':
        // 人均得分：小组总分 = (成员数 × 学生初始分 + 成员当期积分变动总和) ÷ 成员数
        return 'CASE WHEN $mc > 0 THEN ($mc * $si + $ss) / $mc ELSE 0 END';
      case 'sum':
      default:
        // 学生得分总和：小组总分 = 成员数 × 学生初始分 + 成员当期积分变动总和
        return '$mc * $si + $ss';
    }
  }

  // ---- USB Keys ----
  Future<List<Map<String, dynamic>>> getUsbKeys() async {
    final db = await database;
    return db.query('usb_keys', orderBy: 'id');
  }

  Future<int> insertUsbKey(Map<String, dynamic> map) async {
    final db = await database;
    return db.insert('usb_keys', map);
  }

  Future<int> deleteUsbKey(int id) async {
    final db = await database;
    return db.delete('usb_keys', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> updateUsbKeyLabel(int id, String label) async {
    final db = await database;
    return db.update(
      'usb_keys',
      {'label': label},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---- Course Schedule ----
  Future<List<Map<String, dynamic>>> getCourseSchedules() async {
    final db = await database;
    return db.query(
      'course_schedule',
      where: 'deleted_at IS NULL',
      orderBy: 'weekday, start_time',
    );
  }

  Future<List<Map<String, dynamic>>> getCourseSchedulesByWeekday(
    int weekday,
  ) async {
    final db = await database;
    return db.query(
      'course_schedule',
      where: 'weekday = ?',
      whereArgs: [weekday],
      orderBy: 'start_time',
    );
  }

  Future<int> insertCourseSchedule(Map<String, dynamic> map) async {
    final db = await database;
    return db.insert('course_schedule', map);
  }

  Future<int> updateCourseSchedule(int id, Map<String, dynamic> map) async {
    final db = await database;
    return db.update('course_schedule', map, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteCourseSchedule(int id) async {
    final db = await database;
    return db.delete('course_schedule', where: 'id = ?', whereArgs: [id]);
  }

  /// Replace the whole course schedule table with [rows] in one transaction.
  /// Used by the table editor and the "overwrite" import mode.
  ///
  /// 走**差异**而不是"全删再全插"：v11 把删除改成墓碑，全删全插会让每次
  /// 保存都把整张课表换成一批全新 uid 的行——对端看到"整个课表被删掉又
  /// 重建"，几十条墓碑事件白白传播，并发的改动也变成不可解释的冲突。
  ///
  /// 判等用业务三元组（星期几 + 课程名 + 起止时间），因为那是课表在界面上
  /// 唯一的身份；uid 只在"保留同一行"时才有意义。
  Future<void> replaceAllCourseSchedules(List<Map<String, dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'course_schedule',
        where: 'deleted_at IS NULL',
      );
      String keyOf(Map<String, dynamic> row) =>
          '${row['weekday']}|${row['course_name']}|'
          '${row['start_time']}|${row['end_time']}';

      final byKey = {for (final row in existing) keyOf(row): row};
      final keptIds = <int>{};

      for (final row in rows) {
        final match = byKey[keyOf(row)];
        if (match != null) {
          // 内容一致：什么都不做，uid 与 rev 原样保住。
          keptIds.add(match['id'] as int);
        } else {
          await txn.insert('course_schedule', row);
        }
      }

      for (final row in existing) {
        if (keptIds.contains(row['id'])) continue;
        await txn.delete(
          'course_schedule',
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    });
  }

  /// Append multiple course schedules in one transaction.
  Future<void> insertCourseSchedules(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final row in rows) {
        await txn.insert('course_schedule', row);
      }
    });
  }

  // ---- Schedule Adjustment (调休) ----

  Future<List<Map<String, dynamic>>> getScheduleAdjustments() async {
    final db = await database;
    return db.query(
      'schedule_adjustment',
      where: 'deleted_at IS NULL',
      orderBy: 'date',
    );
  }

  /// 新增或覆盖某一天的调休设置（date 唯一）。
  ///
  /// v11 之后**不能**再"先删后插"：删除会变成墓碑，唯一索引又是部分索引
  /// （`WHERE deleted_at IS NULL`），于是插入能成功——但每改一次调休就多
  /// 一条墓碑事件传播出去，对端看到的是"这天先被删掉又新建"。
  /// 已有行就原地更新，保住 uid。
  Future<void> upsertScheduleAdjustment(Map<String, dynamic> map) async {
    final db = await database;
    await db.transaction((txn) async {
      // 查**所有**同 date 的行，包括墓碑。
      //
      // 为什么不能只查 deleted_at IS NULL 的那些：`date` 上有列内联的
      // `UNIQUE`（建表时就写死了），它生成的隐式索引删不掉，部分索引
      // `WHERE deleted_at IS NULL` 只是额外的第二道约束。于是"删掉某天调休
      // 再设回来"会直接撞 UNIQUE —— 墓碑行还在，只是看不见。
      // 正确做法是原地复活那一行，保住 uid。
      final existing = await txn.query(
        'schedule_adjustment',
        columns: ['id'],
        where: 'date = ?',
        whereArgs: [map['date']],
        orderBy: 'deleted_at IS NULL DESC, id DESC',
        limit: 1,
      );
      if (existing.isNotEmpty) {
        await txn.update(
          'schedule_adjustment',
          {...map, 'deleted_at': null},
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
        return;
      }
      await txn.insert('schedule_adjustment', map);
    });
  }

  Future<int> deleteScheduleAdjustment(String date) async {
    final db = await database;
    return db.delete(
      'schedule_adjustment',
      where: 'date = ?',
      whereArgs: [date],
    );
  }

  /// 删除 [dateKey]（yyyy-MM-dd）之前（含当天之前）的调休记录，返回删除条数。
  Future<int> deleteScheduleAdjustmentsBefore(String dateKey) async {
    final db = await database;
    return db.delete(
      'schedule_adjustment',
      where: 'date < ?',
      whereArgs: [dateKey],
    );
  }

  // ---- Groups ----
  Future<List<Map<String, dynamic>>> getGroups() async {
    final db = await database;
    return db.query('groups', where: 'deleted_at IS NULL', orderBy: 'id');
  }

  /// 获取默认分组“未分组”的 id；如果不存在则自动创建并返回新 id。
  Future<int> getOrCreateDefaultGroupId() async {
    final db = await database;
    final rows = await db.query(
      'groups',
      columns: ['id'],
      where: 'name = ?',
      whereArgs: ['未分组'],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return rows.first['id'] as int;
    }
    return db.insert('groups', {'name': '未分组'});
  }

  /// 获取下一个递增的学号（作为字符串），如果表中没有学号则返回 '1'。
  Future<String> getNextStudentNumber() async {
    final db = await database;
    // 使用 CAST 将 student_number 转为整数进行比较，忽略非数字的情况。
    final result = await db.rawQuery(
      'SELECT MAX(CAST(student_number AS INTEGER)) as max_num FROM students '
      'WHERE deleted_at IS NULL',
    );
    final maxNum = result.first['max_num'] as int?;
    final nextNum = (maxNum ?? 0) + 1;
    return nextNum.toString();
  }

  Future<int> insertGroup(Map<String, dynamic> map) async {
    final db = await database;
    return db.insert('groups', map);
  }

  Future<int> updateGroup(int id, Map<String, dynamic> map) async {
    final db = await database;
    return db.update('groups', map, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteGroup(int id) async {
    final db = await database;
    await db.delete('students', where: 'group_id = ?', whereArgs: [id]);
    return db.delete('groups', where: 'id = ?', whereArgs: [id]);
  }

  // ---- Students ----
  Future<List<Map<String, dynamic>>> getStudents({int? groupId}) async {
    final db = await database;
    if (groupId != null) {
      return db.query(
        'students',
        where: 'group_id = ? AND deleted_at IS NULL',
        whereArgs: [groupId],
        orderBy: 'id',
      );
    }
    return db.query('students', where: 'deleted_at IS NULL', orderBy: 'id');
  }

  Future<List<Map<String, dynamic>>> getStudentsWithGroupName({
    int? groupId,
  }) async {
    final db = await database;
    String query = '''
      SELECT students.*, groups.name as group_name
      FROM students
      LEFT JOIN groups ON students.group_id = groups.id
      WHERE students.deleted_at IS NULL
    ''';
    List<dynamic>? whereArgs;
    if (groupId != null) {
      query += ' AND students.group_id = ?';
      whereArgs = [groupId];
    }
    query += ' ORDER BY students.id';
    return db.rawQuery(query, whereArgs);
  }

  Future<int> insertStudent(Map<String, dynamic> map) async {
    final db = await database;
    return db.insert('students', map);
  }

  Future<int> updateStudent(int id, Map<String, dynamic> map) async {
    final db = await database;
    return db.update('students', map, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteStudent(int id) async {
    final db = await database;
    return db.delete('students', where: 'id = ?', whereArgs: [id]);
  }

  /// 批量删除学生（一条语句删完，避免逐条往返）。
  Future<int> deleteStudents(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(', ');
    return db.delete(
      'students',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  // ---- Score Records ----
  /// 查询评分记录（按时间倒序）。
  ///
  /// [startDate] / [endDate] 为 ISO 时间串，用于把「只要今天 / 某段日期」的过滤
  /// 下推到 SQL——仪表盘以前是把整个周期的记录全读进内存再用 Dart 过滤。
  /// [limit] 直接加到 SQL 的 LIMIT 上（例如「最近 5 条」）。
  Future<List<Map<String, dynamic>>> getScoreRecords({
    String? targetType,
    int? targetId,
    int? period,
    String? startDate,
    String? endDate,
    int? limit,
  }) async {
    final db = await database;
    String query = '''
      SELECT score_records.*,
             CASE
               WHEN score_records.target_type = 'group' THEN groups.name
               WHEN score_records.target_type = 'student' THEN students.name
             END as target_name,
             CASE
               WHEN score_records.target_type = 'student' THEN students.student_number
             END as target_student_number,
             CASE
               WHEN score_records.target_type = 'student' THEN students.include_in_group_total
             END as target_include_in_group_total,
             score_items.name as score_item_name
       FROM score_records
       LEFT JOIN groups ON score_records.target_type = 'group' AND score_records.target_id = groups.id
       LEFT JOIN students ON score_records.target_type = 'student' AND score_records.target_id = students.id
       LEFT JOIN score_items ON score_records.score_item_id = score_items.id
     ''';
    List<dynamic> whereArgs = [];
    // 软删除：墓碑记录不参与明细列表。
    // 孤儿记录**不过滤**——明细是历史，删了人也该看得见，见 orphanRecordFilter。
    final List<String> conditions = ['score_records.deleted_at IS NULL'];

    // 按周期过滤
    if (period != null) {
      conditions.add('score_records.period = ?');
      whereArgs.add(period);
    }

    if (targetType != null) {
      conditions.add('score_records.target_type = ?');
      whereArgs.add(targetType);
      if (targetId != null) {
        conditions.add('score_records.target_id = ?');
        whereArgs.add(targetId);
      }
    }

    // 日期范围：create_time 是固定宽度的 ISO 串，字符串比较即时间比较。
    if (startDate != null) {
      conditions.add('score_records.create_time >= ?');
      whereArgs.add(startDate);
    }
    if (endDate != null) {
      conditions.add('score_records.create_time <= ?');
      whereArgs.add(endDate);
    }

    if (conditions.isNotEmpty) {
      query += ' WHERE ${conditions.join(' AND ')}';
    }

    query += ' ORDER BY score_records.create_time DESC';
    if (limit != null) {
      query += ' LIMIT ${limit.clamp(1, 100000)}';
    }
    return db.rawQuery(query, whereArgs);
  }

  Future<int> insertScoreRecord(Map<String, dynamic> map) async {
    final db = await database;
    return db.insert('score_records', map);
  }

  /// 批量插入评分记录（使用事务保证原子性）
  /// 返回成功插入的记录数
  Future<int> batchInsertScoreRecords(
    List<Map<String, dynamic>> records,
  ) async {
    final db = await database;
    int count = 0;
    await db.transaction((txn) async {
      for (final record in records) {
        await txn.insert('score_records', record);
        count++;
      }
    });
    return count;
  }

  Future<int> deleteScoreRecord(int id) async {
    final db = await database;
    return db.delete('score_records', where: 'id = ?', whereArgs: [id]);
  }

  /// 批量删除评分记录（事务保证原子性）
  Future<int> deleteScoreRecords(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final db = await database;
    int count = 0;
    await db.transaction((txn) async {
      for (final id in ids) {
        await txn.delete('score_records', where: 'id = ?', whereArgs: [id]);
        count++;
      }
    });
    return count;
  }

  /// 通用更新 score_records 指定字段（用于补充/修改变动原因时绑定预设项/分值等）
  Future<int> updateScoreRecordFields(int id, Map<String, dynamic> values) async {
    if (values.isEmpty) return 0;
    final db = await database;
    return db.update('score_records', values, where: 'id = ?', whereArgs: [id]);
  }

  /// 更新评分记录的变动原因（用于快速评分记录补充原因）
  Future<int> updateScoreRecordReason(int id, String? reason) async {
    final db = await database;
    return db.update(
      'score_records',
      {'reason': reason ?? ''},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---- Score Record Logs / Archive (回收站与修改历史) ----

  /// 读取单条评分记录（不含连表），用于写库前计算变更历史。
  Future<Map<String, dynamic>?> getScoreRecordRaw(int id) async {
    final db = await database;
    final rows = await db.query(
      'score_records',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 写入一条修改记录历史。actionType: create/supplement/update/delete。
  Future<int> insertScoreRecordLog(Map<String, dynamic> map) async {
    final db = await database;
    return db.insert('score_record_logs', map);
  }

  /// 获取某条评分记录的修改历史（按时间倒序，最新在前）。
  Future<List<Map<String, dynamic>>> getScoreRecordLogs(int recordId) async {
    final db = await database;
    return db.query(
      'score_record_logs',
      where: 'record_id = ?',
      whereArgs: [recordId],
      orderBy: 'id DESC',
    );
  }

  /// 批量插入评分记录并返回每条新记录的主键 id（用于写入“新增”历史）。
  Future<List<int>> insertScoreRecordsReturningIds(
    List<Map<String, dynamic>> records,
  ) async {
    final db = await database;
    final ids = <int>[];
    await db.transaction((txn) async {
      for (final record in records) {
        final id = await txn.insert('score_records', record);
        ids.add(id);
      }
    });
    return ids;
  }

  /// 将指定评分记录移入回收站（同时写“删除”历史），并物理移出 score_records。
  /// 返回实际归档的数量。
  Future<int> archiveScoreRecords(List<int> ids, String deletedAt) async {
    if (ids.isEmpty) return 0;
    final db = await database;
    int count = 0;
    await db.transaction((txn) async {
      for (final id in ids) {
        final rows = await txn.query(
          'score_records',
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final r = rows.first;
        await txn.insert('score_record_archives', {
          'record_id': id,
          'target_type': r['target_type'],
          'target_id': r['target_id'],
          'score': r['score'],
          'reason': r['reason'],
          'score_item_id': r['score_item_id'],
          'custom_name': r['custom_name'],
          'create_time': r['create_time'],
          'period': r['period'],
          'is_quick': r['is_quick'] ?? 0,
          'deleted_at': deletedAt,
        });
        await txn.insert('score_record_logs', {
          'record_id': id,
          'action_type': 'delete',
          'field': null,
          'old_value': null,
          'new_value': null,
          'content': '记录已删除，进入回收站',
          'log_time': deletedAt,
        });
        await txn.delete('score_records', where: 'id = ?', whereArgs: [id]);
        count++;
      }
    });
    return count;
  }

  /// 从回收站恢复指定记录到 score_records（保留原主键，从而延续其修改历史）。
  /// 若其目标学生/小组已被删除则无法恢复，返回 0。
  Future<int> restoreArchivedRecord(int archiveId) async {
    final db = await database;
    int restored = 0;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'score_record_archives',
        where: 'id = ?',
        whereArgs: [archiveId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final a = rows.first;
      final targetType = a['target_type'] as String;
      final targetId = a['target_id'] as int;

      // 校验目标对象是否仍存在，避免恢复成“未知”对象
      bool targetExists;
      if (targetType == 'student') {
        targetExists =
            (await txn.query(
              'students',
              columns: ['id'],
              where: 'id = ?',
              whereArgs: [targetId],
              limit: 1,
            )).isNotEmpty;
      } else if (targetType == 'group') {
        targetExists =
            (await txn.query(
              'groups',
              columns: ['id'],
              where: 'id = ?',
              whereArgs: [targetId],
              limit: 1,
            )).isNotEmpty;
      } else {
        targetExists = true;
      }
      if (!targetExists) return;

      // v11 之后"删除"是墓碑，原行还躺在表里（id 不变）。
      // 这时候直接 INSERT 原主键必然撞 UNIQUE(score_records.id)，
      // 回收站就再也恢复不了了 —— 所以先看行还在不在：
      // 在就原地"复活"（清空 deleted_at），不在才真的插入。
      final tombstoned = await txn.query(
        'score_records',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [a['record_id']],
        limit: 1,
      );
      final payload = <String, Object?>{
        'target_type': targetType,
        'target_id': targetId,
        'score': a['score'],
        'reason': a['reason'],
        'score_item_id': a['score_item_id'],
        'custom_name': a['custom_name'],
        'create_time': a['create_time'],
        'period': a['period'],
        'is_quick': a['is_quick'] ?? 0,
      };
      if (tombstoned.isNotEmpty) {
        await txn.update(
          'score_records',
          {...payload, 'deleted_at': null},
          where: 'id = ?',
          whereArgs: [a['record_id']],
        );
      } else {
        await txn.insert('score_records', {
          'id': a['record_id'],
          ...payload,
        });
      }
      await txn.delete(
        'score_record_archives',
        where: 'id = ?',
        whereArgs: [archiveId],
      );
      restored = 1;
    });
    return restored;
  }

  /// 永久删除回收站记录（同时清除其修改历史）。返回删除的数量。
  Future<int> permanentlyDeleteArchivedRecords(List<int> archiveIds) async {
    if (archiveIds.isEmpty) return 0;
    final db = await database;
    int count = 0;
    await db.transaction((txn) async {
      for (final archiveId in archiveIds) {
        final rows = await txn.query(
          'score_record_archives',
          columns: ['record_id'],
          where: 'id = ?',
          whereArgs: [archiveId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final recordId = rows.first['record_id'] as int;
        await txn.delete(
          'score_record_logs',
          where: 'record_id = ?',
          whereArgs: [recordId],
        );
        await txn.delete(
          'score_record_archives',
          where: 'id = ?',
          whereArgs: [archiveId],
        );
        count++;
      }
    });
    return count;
  }

  /// 清理回收站中超过保留期（默认 7 天）的记录，同时清除其修改历史。
  Future<int> purgeExpiredArchives({
    required DateTime now,
    required Duration retention,
  }) async {
    final db = await database;
    final cutoff = now.subtract(retention).toIso8601String();
    final rows = await db.query(
      'score_record_archives',
      columns: ['id', 'record_id'],
      where: 'deleted_at < ?',
      whereArgs: [cutoff],
    );
    if (rows.isEmpty) return 0;
    final archiveIds = rows.map((r) => r['id'] as int).toList();
    final recordIds = rows.map((r) => r['record_id'] as int).toList();
    int count = 0;
    await db.transaction((txn) async {
      for (final recordId in recordIds) {
        await txn.delete(
          'score_record_logs',
          where: 'record_id = ?',
          whereArgs: [recordId],
        );
      }
      for (final archiveId in archiveIds) {
        await txn.delete(
          'score_record_archives',
          where: 'id = ?',
          whereArgs: [archiveId],
        );
        count++;
      }
    });
    return count;
  }

  /// 读取回收站记录（含被删除记录的目标名/学号/评分项名）。
  Future<List<Map<String, dynamic>>> getArchivedRecords() async {
    final db = await database;
    return db.rawQuery('''
      SELECT a.*,
             CASE
               WHEN a.target_type = 'group' THEN g.name
               WHEN a.target_type = 'student' THEN s.name
             END as target_name,
             CASE
               WHEN a.target_type = 'student' THEN s.student_number
             END as target_student_number,
             CASE
               WHEN a.target_type = 'student' THEN s.include_in_group_total
             END as target_include_in_group_total,
             si.name as score_item_name
      FROM score_record_archives a
      LEFT JOIN groups g ON a.target_type = 'group' AND a.target_id = g.id
      LEFT JOIN students s ON a.target_type = 'student' AND a.target_id = s.id
      LEFT JOIN score_items si ON a.score_item_id = si.id
      ORDER BY a.deleted_at DESC
    ''');
  }

  // ---- Score Items ----
  Future<List<Map<String, dynamic>>> getScoreItems() async {
    final db = await database;
    return db.query('score_items', where: 'deleted_at IS NULL', orderBy: 'id');
  }

  Future<int> insertScoreItem(Map<String, dynamic> map) async {
    final db = await database;
    return db.insert('score_items', map);
  }

  Future<int> updateScoreItem(int id, Map<String, dynamic> map) async {
    final db = await database;
    return db.update('score_items', map, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteScoreItem(int id) async {
    final db = await database;
    return db.delete('score_items', where: 'id = ?', whereArgs: [id]);
  }

  // ---- Advanced Queries ----
  /// 排除"不参与小组总分"（students.include_in_group_total = 0）的学生评分记录。
  /// 仅用于小组维度的「汇总统计」（扇形图分布、总加分/扣分、日均等）；
  /// 「评分变动记录」列表始终完整展示这些学生的记录，不做排除。
  /// 记录目标为小组类型、或目标学生已不存在时不受影响。
  static const String _excludeNotInGroupTotalFilter =
      "(score_records.target_type <> 'student' OR score_records.target_id IN "
      "(SELECT id FROM students WHERE include_in_group_total = 1))";

  /// 查询评分记录明细（用于「评分变动记录」列表）。
  /// 不做"不参与小组总分"过滤：这些学生的记录也要展示，只是不计入
  /// 小组总分、扇形图等统计数据（见 [getScoreDistributionByItem] 等）。
  Future<List<Map<String, dynamic>>> getScoreRecordsAdvanced({
    String? targetType,
    int? targetId,
    String? startDate,
    String? endDate,
    int? period,
  }) async {
    final db = await database;
    String query;
    List<dynamic> whereArgs = [];
    // 软删除：墓碑记录不进入明细列表。
    // 孤儿记录**不过滤**——明细是历史，删了人也该看得见。
    final List<String> conditions = ['score_records.deleted_at IS NULL'];

    // 当查询小组数据且指定了具体小组时，通过 students 表关联获取小组成员的评分记录
    if (targetType == 'group' && targetId != null) {
      query = '''
        SELECT score_records.*,
               CASE
                 WHEN score_records.target_type = 'group' THEN groups.name
                 WHEN score_records.target_type = 'student' THEN students.name
               END as target_name,
               CASE
                 WHEN score_records.target_type = 'student' THEN students.student_number
               END as target_student_number,
               CASE
                 WHEN score_records.target_type = 'student' THEN students.include_in_group_total
               END as target_include_in_group_total,
               score_items.name as score_item_name
        FROM score_records
        LEFT JOIN groups ON score_records.target_type = 'group' AND score_records.target_id = groups.id
        LEFT JOIN students ON score_records.target_type = 'student' AND score_records.target_id = students.id
        LEFT JOIN score_items ON score_records.score_item_id = score_items.id
        WHERE score_records.target_type = 'student'
          AND score_records.deleted_at IS NULL
          AND students.id IN (
            SELECT id FROM students WHERE group_id = ? AND deleted_at IS NULL
          )
      ''';
      whereArgs = [targetId];
      // 周期条件追加到 WHERE 子句后面
      if (period != null) {
        query += ' AND score_records.period = ?';
        whereArgs.add(period);
      }
    } else {
      query = '''
        SELECT score_records.*,
               CASE
                 WHEN score_records.target_type = 'group' THEN groups.name
                 WHEN score_records.target_type = 'student' THEN students.name
               END as target_name,
               CASE
                 WHEN score_records.target_type = 'student' THEN students.student_number
               END as target_student_number,
               CASE
                 WHEN score_records.target_type = 'student' THEN students.include_in_group_total
               END as target_include_in_group_total,
               score_items.name as score_item_name
        FROM score_records
        LEFT JOIN groups ON score_records.target_type = 'group' AND score_records.target_id = groups.id
        LEFT JOIN students ON score_records.target_type = 'student' AND score_records.target_id = students.id
        LEFT JOIN score_items ON score_records.score_item_id = score_items.id
      ''';
      // 按周期过滤
      if (period != null) {
        conditions.add('score_records.period = ?');
        whereArgs.add(period);
      }
      // 当 targetType = 'group' 但 targetId = null（选择"全部小组"）时，不添加 target_type 过滤
      // 因为用户的评分记录都是 target_type = 'student'
      if (targetType != null && targetType != 'group') {
        conditions.add('score_records.target_type = ?');
        whereArgs.add(targetType);
        if (targetId != null) {
          conditions.add('score_records.target_id = ?');
          whereArgs.add(targetId);
        }
      }
    }
    if (startDate != null) {
      conditions.add('score_records.create_time >= ?');
      whereArgs.add(startDate);
    }
    if (endDate != null) {
      conditions.add('score_records.create_time <= ?');
      whereArgs.add(endDate);
    }

    if (conditions.isNotEmpty) {
      query += ' WHERE ${conditions.join(' AND ')}';
    }
    query += ' ORDER BY score_records.create_time DESC';
    return db.rawQuery(query, whereArgs);
  }

  /// Get score distribution by score_item for pie chart
  Future<List<Map<String, dynamic>>> getScoreDistributionByItem({
    String? targetType,
    int? targetId,
    String? startDate,
    String? endDate,
    int? period,
    bool excludeNotInGroupTotal = false,
  }) async {
    final db = await database;
    List<dynamic> whereArgs = [];
    // 软删除：墓碑记录不参与分布统计。
    final List<String> conditions = ['score_records.deleted_at IS NULL'];

    // 当查询小组数据时，通过 students 表关联获取小组成员的评分记录
    if (targetType == 'group' && targetId != null) {
      var query = '''
        SELECT
          COALESCE(score_items.name, score_records.custom_name, '未分类') as item_name,
          SUM(score_records.score) as total_score,
          COUNT(*) as count
        FROM score_records
        LEFT JOIN score_items ON score_records.score_item_id = score_items.id
        WHERE score_records.target_type = 'student'
          AND score_records.deleted_at IS NULL
          AND score_records.target_id IN (
            SELECT id FROM students WHERE group_id = ? AND deleted_at IS NULL
          )
      ''';
      whereArgs = [targetId];
      // 周期过滤
      if (period != null) {
        query += ' AND score_records.period = ?';
        whereArgs.add(period);
      }
      // 小组维度统计时排除"不参与小组总分"的学生记录
      if (excludeNotInGroupTotal) {
        conditions.add(_excludeNotInGroupTotalFilter);
      }
      if (startDate != null) {
        conditions.add('score_records.create_time >= ?');
        whereArgs.add(startDate);
      }
      if (endDate != null) {
        conditions.add('score_records.create_time <= ?');
        whereArgs.add(endDate);
      }
      if (conditions.isNotEmpty) {
        query += ' AND ${conditions.join(' AND ')}';
      }
      query += ' GROUP BY item_name ORDER BY total_score DESC';
      return db.rawQuery(query, whereArgs);
    } else {
      String query = '''
        SELECT
          COALESCE(score_items.name, score_records.custom_name, '未分类') as item_name,
          SUM(score_records.score) as total_score,
          COUNT(*) as count
        FROM score_records
        LEFT JOIN score_items ON score_records.score_item_id = score_items.id
      ''';
      // 周期过滤
      if (period != null) {
        conditions.add('score_records.period = ?');
        whereArgs.add(period);
      }
      // 当 targetType = 'group' 但 targetId = null（选择"全部小组"）时，不添加 target_type 过滤
      // 因为用户的评分记录都是 target_type = 'student'
      if (targetType != null && targetType != 'group') {
        conditions.add('score_records.target_type = ?');
        whereArgs.add(targetType);
        if (targetId != null) {
          conditions.add('score_records.target_id = ?');
          whereArgs.add(targetId);
        }
      }
      // 小组维度统计时排除"不参与小组总分"的学生记录
      if (excludeNotInGroupTotal) {
        conditions.add(_excludeNotInGroupTotalFilter);
      }
      // 孤儿记录（目标已被删）不进分布统计，见 orphanRecordFilter。
      conditions.add(orphanRecordFilter);
      conditions.add(orphanGroupRecordFilter);
      if (startDate != null) {
        conditions.add('score_records.create_time >= ?');
        whereArgs.add(startDate);
      }
      if (endDate != null) {
        conditions.add('score_records.create_time <= ?');
        whereArgs.add(endDate);
      }
      if (conditions.isNotEmpty) {
        query += ' WHERE ${conditions.join(' AND ')}';
      }
      query += ' GROUP BY item_name ORDER BY total_score DESC';
      return db.rawQuery(query, whereArgs);
    }
  }

  /// Get average daily positive/negative scores
  Future<Map<String, dynamic>> getAverageDailyScores({
    String? targetType,
    int? targetId,
    int? period,
    bool excludeNotInGroupTotal = false,
  }) async {
    final db = await database;

    // 当查询小组数据时，通过 students 表关联获取小组成员的评分记录
    if (targetType == 'group' && targetId != null) {
      String query = '''
        SELECT
          COALESCE(SUM(CASE WHEN score > 0 THEN score ELSE 0 END), 0) as total_positive,
          COALESCE(SUM(CASE WHEN score < 0 THEN score ELSE 0 END), 0) as total_negative,
          COUNT(DISTINCT DATE(create_time)) as scored_days
        FROM score_records
        WHERE score_records.target_type = 'student' AND score_records.target_id IN (
          SELECT id FROM students WHERE group_id = ? AND deleted_at IS NULL
        )
        AND score_records.deleted_at IS NULL
      ''';
      List<dynamic> whereArgs = [targetId];
      // 周期过滤
      if (period != null) {
        query += ' AND score_records.period = ?';
        whereArgs.add(period);
      }
      // 小组维度统计时排除"不参与小组总分"的学生记录
      if (excludeNotInGroupTotal) {
        query += ' AND $_excludeNotInGroupTotalFilter';
      }
      final result = await db.rawQuery(query, whereArgs);

      if (result.isNotEmpty) {
        final r = result.first;
        final totalPositive = (r['total_positive'] as num?)?.toDouble() ?? 0.0;
        final totalNegative = (r['total_negative'] as num?)?.toDouble() ?? 0.0;
        final days = (r['scored_days'] as int?) ?? 0;
        return {
          'total_positive': totalPositive,
          'total_negative': totalNegative,
          'avg_positive': days > 0 ? totalPositive / days : 0.0,
          'avg_negative': days > 0 ? totalNegative / days : 0.0,
          'scored_days': days,
        };
      }
      return {
        'total_positive': 0.0,
        'total_negative': 0.0,
        'avg_positive': 0.0,
        'avg_negative': 0.0,
        'scored_days': 0,
      };
    }

    List<dynamic> whereArgs = [];
    // 软删除：墓碑记录不参与统计。
    final List<String> conditions = ['score_records.deleted_at IS NULL'];
    // 周期过滤
    if (period != null) {
      conditions.add('score_records.period = ?');
      whereArgs.add(period);
    }
    // 当 targetType = 'group' 但 targetId = null（选择"全部小组"）时，不添加 target_type 过滤
    // 因为用户的评分记录都是 target_type = 'student'
    if (targetType != null && targetType != 'group') {
      conditions.add('score_records.target_type = ?');
      whereArgs.add(targetType);
      if (targetId != null) {
        conditions.add('score_records.target_id = ?');
        whereArgs.add(targetId);
      }
    }
    // 小组维度统计时排除"不参与小组总分"的学生记录
    if (excludeNotInGroupTotal) {
      conditions.add(_excludeNotInGroupTotalFilter);
    }
    // 孤儿记录（目标已被删）不进统计，见 orphanRecordFilter。
    conditions.add(orphanRecordFilter);
    conditions.add(orphanGroupRecordFilter);
    final whereClause = conditions.isNotEmpty
        ? 'WHERE ${conditions.join(' AND ')}'
        : '';

    final result = await db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN score > 0 THEN score ELSE 0 END), 0) as total_positive,
        COALESCE(SUM(CASE WHEN score < 0 THEN score ELSE 0 END), 0) as total_negative,
        COUNT(DISTINCT DATE(create_time)) as scored_days
      FROM score_records
      $whereClause
    ''', whereArgs);

    if (result.isNotEmpty) {
      final r = result.first;
      final totalPositive = (r['total_positive'] as num?)?.toDouble() ?? 0.0;
      final totalNegative = (r['total_negative'] as num?)?.toDouble() ?? 0.0;
      final days = (r['scored_days'] as int?) ?? 0;
      return {
        'total_positive': totalPositive,
        'total_negative': totalNegative,
        'avg_positive': days > 0 ? totalPositive / days : 0.0,
        'avg_negative': days > 0 ? totalNegative / days : 0.0,
        'scored_days': days,
      };
    }
    return {
      'total_positive': 0.0,
      'total_negative': 0.0,
      'avg_positive': 0.0,
      'avg_negative': 0.0,
      'scored_days': 0,
    };
  }

  // ---- Statistics ----
  /// 获取指定周期范围内的小组总分。
  /// member_count 为该组全部成员数（含不参与小组总分统计的学生，供统计报表展示）；
  /// total_score 只累计参与统计的成员。
  Future<List<Map<String, dynamic>>> getGroupTotalScoresByPeriodRange({
    int? startPeriod,
    int? endPeriod,
  }) async {
    if (startPeriod == null || endPeriod == null) {
      // 回退到当前周期查询
      return getGroupTotalScores();
    }
    final db = await database;
    final config = await _getScoreConfig();
    final groupExpr = _groupTotalExpr(config: config);
    final query = '''
      SELECT groups.id, groups.name,
             $groupExpr as total_score,
             COALESCE(m.member_count, 0) as member_count
      FROM groups
      LEFT JOIN (
        SELECT s.group_id,
               COUNT(DISTINCT s.id) as member_count,
               COUNT(DISTINCT CASE WHEN s.include_in_group_total = 1 THEN s.id END)
                 as scoring_member_count,
               COALESCE(SUM(CASE WHEN s.include_in_group_total = 1 THEN sr.score ELSE 0 END), 0)
                 as score_sum
        FROM students s
        LEFT JOIN score_records sr
          ON sr.target_type = 'student' AND sr.target_id = s.id
             AND sr.period >= $startPeriod AND sr.period <= $endPeriod
             AND sr.deleted_at IS NULL
        WHERE s.deleted_at IS NULL
        GROUP BY s.group_id
      ) m ON m.group_id = groups.id
      WHERE groups.deleted_at IS NULL
      GROUP BY groups.id ORDER BY total_score DESC
    ''';
    return db.rawQuery(query);
  }

  /// 获取指定周期范围内的学生总分
  Future<List<Map<String, dynamic>>> getStudentTotalScoresByPeriodRange({
    int? startPeriod,
    int? endPeriod,
    int? groupId,
  }) async {
    if (startPeriod == null || endPeriod == null) {
      // 回退到当前周期查询
      return getStudentTotalScores(groupId: groupId);
    }
    final db = await database;
    final config = await _getScoreConfig();
    String query = '''
      SELECT students.id, students.name, students.student_number, students.group_id, groups.name as group_name,
             COALESCE(SUM(score_records.score), 0) + ${config.studentInitial} as total_score
      FROM students
      LEFT JOIN groups ON students.group_id = groups.id
      LEFT JOIN score_records ON score_records.target_type = 'student' AND score_records.target_id = students.id
        AND score_records.period >= ? AND score_records.period <= ?
        AND score_records.deleted_at IS NULL
    ''';
    List<dynamic> whereArgs = [startPeriod, endPeriod];
    final List<String> conditions = ['students.deleted_at IS NULL'];
    if (groupId != null) {
      conditions.add('students.group_id = ?');
      whereArgs.add(groupId);
    }
    if (conditions.isNotEmpty) {
      query += ' WHERE ${conditions.join(' AND ')}';
    }
    query += ' GROUP BY students.id ORDER BY total_score DESC';
    return db.rawQuery(query, whereArgs);
  }

  /// 获取指定周期范围内评分的时间范围（首次评分时间和末次评分时间）
  Future<Map<String, String?>?> getScoreTimeRangeByPeriod({
    int? startPeriod,
    int? endPeriod,
  }) async {
    if (startPeriod == null || endPeriod == null) {
      return null;
    }
    final db = await database;
    final result = await db.rawQuery(
      '''
      SELECT MIN(create_time) as first_score, MAX(create_time) as last_score
      FROM score_records
      WHERE period >= ? AND period <= ?
      LIMIT 1
      ''',
      [startPeriod, endPeriod],
    );
    if (result.isNotEmpty) {
      final r = result.first;
      final firstScore = r['first_score'] as String?;
      final lastScore = r['last_score'] as String?;
      return {'first_score': firstScore, 'last_score': lastScore};
    }
    return null;
  }

  /// 获取当前周期的小组总分。
  /// member_count 为该组全部成员数（含不参与小组总分统计的学生，供统计报表展示）；
  /// total_score 只累计参与统计的成员。
  Future<List<Map<String, dynamic>>> getGroupTotalScores({int? period}) async {
    final db = await database;
    final config = await _getScoreConfig();
    final periodOn = period != null ? 'AND sr.period = $period' : '';
    // 根据计算方式生成小组总分表达式
    final groupExpr = _groupTotalExpr(config: config);
    final query = '''
      SELECT groups.id, groups.name,
             $groupExpr as total_score,
             COALESCE(m.member_count, 0) as member_count
      FROM groups
      LEFT JOIN (
        SELECT s.group_id,
               COUNT(DISTINCT s.id) as member_count,
               COUNT(DISTINCT CASE WHEN s.include_in_group_total = 1 THEN s.id END)
                 as scoring_member_count,
               COALESCE(SUM(CASE WHEN s.include_in_group_total = 1 THEN sr.score ELSE 0 END), 0)
                 as score_sum
        FROM students s
        LEFT JOIN score_records sr
          ON sr.target_type = 'student' AND sr.target_id = s.id $periodOn
             AND sr.deleted_at IS NULL
        WHERE s.deleted_at IS NULL
        GROUP BY s.group_id
      ) m ON m.group_id = groups.id
      WHERE groups.deleted_at IS NULL
      GROUP BY groups.id ORDER BY total_score DESC
    ''';
    return db.rawQuery(query);
  }

  Future<List<Map<String, dynamic>>> getStudentTotalScores({
    int? groupId,
    int? period,
  }) async {
    final db = await database;
    final config = await _getScoreConfig();
    String query = '''
      SELECT students.id, students.name, students.student_number, students.group_id, groups.name as group_name,
             COALESCE(SUM(score_records.score), 0) + ${config.studentInitial} as total_score
      FROM students
      LEFT JOIN groups ON students.group_id = groups.id
      LEFT JOIN score_records ON score_records.target_type = 'student' AND score_records.target_id = students.id
        AND score_records.deleted_at IS NULL
    ''';
    List<dynamic> whereArgs = [];
    // 软删除：墓碑学生不出现在名单里。
    final List<String> conditions = ['students.deleted_at IS NULL'];

    // period 条件必须放在 LEFT JOIN ON 子句中，而非 WHERE 子句，
    // 否则会过滤掉没有当前周期评分记录的学生（LEFT JOIN 降级为 INNER JOIN）。
    if (period != null) {
      query = query.replaceFirst(
        'LEFT JOIN score_records ON score_records.target_type = \'student\' AND score_records.target_id = students.id',
        'LEFT JOIN score_records ON score_records.target_type = \'student\' AND score_records.target_id = students.id'
        ' AND score_records.period = ? AND score_records.deleted_at IS NULL',
      );
      whereArgs.add(period);
    }

    if (groupId != null) {
      conditions.add('students.group_id = ?');
      whereArgs.add(groupId);
    }

    if (conditions.isNotEmpty) {
      query += ' WHERE ${conditions.join(' AND ')}';
    }
    query += ' GROUP BY students.id ORDER BY total_score DESC';
    return db.rawQuery(query, whereArgs);
  }
}
