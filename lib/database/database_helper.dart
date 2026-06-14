import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._();
  DatabaseHelper._();

  Database? _database;

  String get dbDir {
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
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return db;
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
        create_time TEXT NOT NULL
      )
    ''');
    await _createV2Tables(db);
    await _createV3Tables(db);
    await _createV4Tables(db);
    await _createV5Tables(db);
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

  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert('app_settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    return db.query('course_schedule', orderBy: 'weekday, start_time');
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

  // ---- Groups ----
  Future<List<Map<String, dynamic>>> getGroups() async {
    final db = await database;
    return db.query('groups', orderBy: 'id');
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
      'SELECT MAX(CAST(student_number AS INTEGER)) as max_num FROM students',
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
        where: 'group_id = ?',
        whereArgs: [groupId],
        orderBy: 'id',
      );
    }
    return db.query('students', orderBy: 'id');
  }

  Future<List<Map<String, dynamic>>> getStudentsWithGroupName({
    int? groupId,
  }) async {
    final db = await database;
    String query = '''
      SELECT students.*, groups.name as group_name
      FROM students
      LEFT JOIN groups ON students.group_id = groups.id
    ''';
    List<dynamic>? whereArgs;
    if (groupId != null) {
      query += ' WHERE students.group_id = ?';
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

  // ---- Score Records ----
  Future<List<Map<String, dynamic>>> getScoreRecords({
    String? targetType,
    int? targetId,
    int? period,
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
             score_items.name as score_item_name
       FROM score_records
       LEFT JOIN groups ON score_records.target_type = 'group' AND score_records.target_id = groups.id
       LEFT JOIN students ON score_records.target_type = 'student' AND score_records.target_id = students.id
       LEFT JOIN score_items ON score_records.score_item_id = score_items.id
     ''';
    List<dynamic> whereArgs = [];
    List<String> conditions = [];

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

    if (conditions.isNotEmpty) {
      query += ' WHERE ${conditions.join(' AND ')}';
    }

    query += ' ORDER BY score_records.create_time DESC';
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

  // ---- Score Items ----
  Future<List<Map<String, dynamic>>> getScoreItems() async {
    final db = await database;
    return db.query('score_items', orderBy: 'id');
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
    List<String> conditions = [];

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
               score_items.name as score_item_name
        FROM score_records
        LEFT JOIN groups ON score_records.target_type = 'group' AND score_records.target_id = groups.id
        LEFT JOIN students ON score_records.target_type = 'student' AND score_records.target_id = students.id
        LEFT JOIN score_items ON score_records.score_item_id = score_items.id
        WHERE score_records.target_type = 'student' AND students.id IN (
          SELECT id FROM students WHERE group_id = ?
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
  }) async {
    final db = await database;
    List<dynamic> whereArgs = [];
    List<String> conditions = [];

    // 当查询小组数据时，通过 students 表关联获取小组成员的评分记录
    if (targetType == 'group' && targetId != null) {
      var query = '''
        SELECT
          COALESCE(score_items.name, score_records.custom_name, '未分类') as item_name,
          SUM(score_records.score) as total_score,
          COUNT(*) as count
        FROM score_records
        LEFT JOIN score_items ON score_records.score_item_id = score_items.id
        WHERE score_records.target_type = 'student' AND score_records.target_id IN (
          SELECT id FROM students WHERE group_id = ?
        )
      ''';
      whereArgs = [targetId];
      // 周期过滤
      if (period != null) {
        query += ' AND score_records.period = ?';
        whereArgs.add(period);
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
          SELECT id FROM students WHERE group_id = ?
        )
      ''';
      List<dynamic> whereArgs = [targetId];
      // 周期过滤
      if (period != null) {
        query += ' AND score_records.period = ?';
        whereArgs.add(period);
      }
      final result = await db.rawQuery(query, whereArgs);

      if (result.isNotEmpty) {
        final r = result.first;
        final totalPositive = (r['total_positive'] as num?)?.toDouble() ?? 0.0;
        final totalNegative = (r['total_negative'] as num?)?.toDouble() ?? 0.0;
        final days = (r['scored_days'] as int?) ?? 0;
        return {
          'avg_positive': days > 0 ? totalPositive / days : 0.0,
          'avg_negative': days > 0 ? totalNegative / days : 0.0,
          'scored_days': days,
        };
      }
      return {'avg_positive': 0.0, 'avg_negative': 0.0, 'scored_days': 0};
    }

    List<dynamic> whereArgs = [];
    List<String> conditions = [];
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
        'avg_positive': days > 0 ? totalPositive / days : 0.0,
        'avg_negative': days > 0 ? totalNegative / days : 0.0,
        'scored_days': days,
      };
    }
    return {'avg_positive': 0.0, 'avg_negative': 0.0, 'scored_days': 0};
  }

  // ---- Statistics ----
  Future<List<Map<String, dynamic>>> getGroupTotalScores({int? period}) async {
    final db = await database;
    String query = '''
      SELECT groups.id, groups.name, COALESCE(SUM(score_records.score), 0) as total_score
      FROM groups
      LEFT JOIN students ON students.group_id = groups.id
      LEFT JOIN score_records ON score_records.target_type = 'student' AND score_records.target_id = students.id
    ''';
    List<dynamic> whereArgs = [];
    if (period != null) {
      // period 条件必须放在 LEFT JOIN ON 子句中，而非 WHERE 子句，
      // 否则会过滤掉没有当前周期评分记录的小组（LEFT JOIN 降级为 INNER JOIN）。
      query = query.replaceFirst(
        'LEFT JOIN score_records ON score_records.target_type = \'student\' AND score_records.target_id = students.id',
        'LEFT JOIN score_records ON score_records.target_type = \'student\' AND score_records.target_id = students.id AND score_records.period = ?',
      );
      whereArgs.add(period);
    }
    query += ' GROUP BY groups.id ORDER BY total_score DESC';
    return db.rawQuery(query, whereArgs);
  }

  Future<List<Map<String, dynamic>>> getStudentTotalScores({
    int? groupId,
    int? period,
  }) async {
    final db = await database;
    String query = '''
      SELECT students.id, students.name, students.student_number, students.group_id, groups.name as group_name,
             COALESCE(SUM(score_records.score), 0) as total_score
      FROM students
      LEFT JOIN groups ON students.group_id = groups.id
      LEFT JOIN score_records ON score_records.target_type = 'student' AND score_records.target_id = students.id
    ''';
    List<dynamic> whereArgs = [];
    List<String> conditions = [];

    // period 条件必须放在 LEFT JOIN ON 子句中，而非 WHERE 子句，
    // 否则会过滤掉没有当前周期评分记录的学生（LEFT JOIN 降级为 INNER JOIN）。
    if (period != null) {
      query = query.replaceFirst(
        'LEFT JOIN score_records ON score_records.target_type = \'student\' AND score_records.target_id = students.id',
        'LEFT JOIN score_records ON score_records.target_type = \'student\' AND score_records.target_id = students.id AND score_records.period = ?',
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
