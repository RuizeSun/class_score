import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../database/database_helper.dart';
import 'heavy_compute.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database, OpenDatabaseOptions, databaseFactoryFfi;

/// 备份节流器：决定「这次要不要真的复制一份库」。
///
/// 备份是写入前的安全网，不是撤销栈：同一份数据在几分钟内几乎一样，而一次
/// 备份要复制整个库文件——评分高峰期每点一次就整库复制一次，既慢又费盘。
/// 拆成独立的纯逻辑类（不碰文件系统、时钟可注入），便于单测覆盖
/// 「首次 / 间隔内 / 超过间隔 / 强制」四种情形。
class BackupThrottle {
  BackupThrottle({required this.minInterval, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// 两次自动备份之间的最短间隔。
  final Duration minInterval;

  final DateTime Function() _clock;

  DateTime? _lastRunAt;

  /// 现在是否应该备份。
  ///
  /// [force] 表示「用户显式要求」或「整库级破坏性操作」（导出、导入、重置、
  /// 覆盖导入），不受节流限制。
  bool shouldRun({bool force = false}) {
    if (force) return true;
    final last = _lastRunAt;
    if (last == null) return true;
    return _clock().difference(last) >= minInterval;
  }

  /// 记录一次真正开始的备份时刻。
  void markRun() => _lastRunAt = _clock();

  /// 清除「上次备份时刻」（测试用：单例节流器状态会跨用例残留）。
  @visibleForTesting
  void resetForTest() => _lastRunAt = null;
}

class BackupService {
  static final BackupService instance = BackupService._();
  BackupService._();

  static const int maxBackups = 50;

  /// 自动备份的最短间隔（见 [BackupThrottle]）。
  static const Duration minInterval = Duration(minutes: 3);

  /// 备份目录覆盖（测试用；默认是数据库同级的 `../backups`）。
  @visibleForTesting
  static String? backupDirOverride;

  final BackupThrottle _throttle = BackupThrottle(minInterval: minInterval);

  /// 正在进行的备份：并发调用等同一份结果，避免两次「快照 / 复制」交错。
  Future<String?>? _inFlight;

  /// 已排进延后队列、尚未开始的备份（见 [scheduleBackup]）。
  bool _scheduled = false;

  /// 延后队列的定时器。必须持有句柄：退出程序时要能把这次备份**立刻补上**，
  /// 否则「写完就退出」会连唯一一份快照一起丢掉。
  Timer? _scheduledTimer;

  /// [scheduleBackup] 的延后时长：让评分提交后的重载查询先跑完。
  static const Duration scheduledDelay = Duration(milliseconds: 400);

  String get backupDir {
    return backupDirOverride ??
        p.join(DatabaseHelper.instance.dbDir, '..', 'backups');
  }

  Future<void> ensureBackupDir() async {
    final dir = Directory(backupDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// 创建一份整库备份，返回备份文件路径（被节流跳过或失败时返回 null）。
  ///
  /// **不关库**：优先用 SQLite 的 `VACUUM INTO` 在现有连接上做一致性快照，
  /// 因此备份期间其它查询照常可用——旧实现是「关库 → 复制文件 → 重开」，
  /// 每次写操作都跑一遍，既慢又会让并发查询撞上「数据库已关闭」。
  /// 节流见 [minInterval]；导入 / 重置 / 导出等显式操作请传 [force]。
  Future<String?> createBackup({bool force = false}) {
    final running = _inFlight;
    if (running != null) return running;
    if (!_throttle.shouldRun(force: force)) {
      return Future<String?>.value(null);
    }
    final future = _createBackup();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  /// 日常写入（记分 / 改规则 / 增删学生…）用的备份入口：**不阻塞调用方**。
  ///
  /// 为什么要延后而不是直接 `unawaited(createBackup())`：
  /// 评分提交的顺序是「写记录 → 重载列表 → 重载统计」，三步都排在数据库那条连接
  /// 上。`VACUUM INTO` 是整库重写，如果它抢在重载查询之前排队，用户看到的就是
  /// 「点完确认，界面先冻一下再出结果」——这正是掉帧的主因。
  /// 这里把备份推到下一帧之后、再延后 [scheduledDelay]，让重载查询先跑完；
  /// 备份本身照常执行，只是不再挡在提交路径上。
  ///
  /// 节流与单飞语义与 [createBackup] 一致：一次排队期间再次调用只算一次。
  /// 不做 `force`——真正需要「先有备份再动手」的破坏性操作请显式 await
  /// [createBackup] `force: true`。
  void scheduleBackup() {
    if (_scheduled) return;
    if (!_throttle.shouldRun()) return;
    _scheduled = true;
    // 只用一个定时器，**不依赖帧回调**。
    //
    // 提交评分时紧随其后还要跑「重载记录 + 重载统计」两批查询，它们都已经排在
    // 数据库连接上；这里延后 [scheduledDelay] 就能保证那些查询先执行完，快照
    // 排在它们之后。为什么不用 addPostFrameCallback：窗口闲置（没有动画、没有
    // 交互）时 Flutter 不调度新帧，帧回调可能迟迟不触发，备份就被无限拖延了。
    _scheduledTimer?.cancel();
    _scheduledTimer = Timer(scheduledDelay, () {
      _scheduledTimer = null;
      _scheduled = false;
      unawaited(createBackup());
    });
  }

  /// 是否有备份还排着队（退出前判断要不要等它）。
  bool get hasPendingBackup => _scheduledTimer != null;

  /// 立刻执行排队中的备份（退出程序前调用），返回是否真的补了一次。
  ///
  /// 延后队列是为「不卡提交」设计的：如果把等待留到进程结束时，exit(0) 会
  /// 连同这份快照一起丢掉。因此退出路径必须显式 flush 一次。
  Future<bool> flushPendingBackup() async {
    final timer = _scheduledTimer;
    if (timer == null) return false;
    timer.cancel();
    _scheduledTimer = null;
    _scheduled = false;
    await createBackup(force: true);
    return true;
  }

  /// 重置节流与排队状态（测试用：单例状态会跨用例残留）。
  @visibleForTesting
  void resetForTest() {
    // 定时器也要撤掉：否则上一个用例排队的备份会落进下一个用例的目录，
    // 让「延后时长过后备份真的出现」变成假通过。
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    _throttle.resetForTest();
    _scheduled = false;
  }

  Future<String?> _createBackup() async {
    try {
      await ensureBackupDir();
      final backupPath = _newBackupPath();
      if (!await _snapshot(backupPath)) return null;
      _throttle.markRun();
      // Cleanup old backups
      await _cleanupOldBackups();
      return backupPath;
    } catch (e) {
      debugPrint('创建备份失败：$e');
      return null;
    }
  }

  /// 备份文件名：时间戳精确到毫秒，避免同一秒内的两次备份互相覆盖。
  String _newBackupPath() {
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return p.join(backupDir, 'backup_$timestamp.db');
  }

  /// 一致性地把当前库落成 [backupPath]；失败返回 false（不留半成品文件）。
  Future<bool> _snapshot(String backupPath) async {
    if (await _snapshotWithVacuumInto(backupPath)) return true;
    return _snapshotByFileCopy(backupPath);
  }

  /// `VACUUM INTO`：在线快照，不需要关库，也不会阻塞其它查询。
  Future<bool> _snapshotWithVacuumInto(String backupPath) async {
    try {
      final db = await DatabaseHelper.instance.database;
      await db.execute('VACUUM INTO ?', [backupPath]);
      return true;
    } catch (error) {
      debugPrint('VACUUM INTO 备份失败，改用文件复制：$error');
      // 失败可能留下半成品文件，复制前先清掉，免得占着目标文件名。
      await _deleteIfExists(backupPath);
      return false;
    }
  }

  /// 兜底：老 SQLite（< 3.27）不支持 `VACUUM INTO`，退回「关库 → 复制 → 重开」。
  /// 这条路径会让并发查询短暂看到「库已关闭」，因此只作兜底，不再每写一次就跑。
  Future<bool> _snapshotByFileCopy(String backupPath) async {
    try {
      await DatabaseHelper.instance.closeDatabase();
      await File(DatabaseHelper.instance.dbPath).copy(backupPath);
      return true;
    } catch (error) {
      debugPrint('复制数据库文件备份失败：$error');
      return false;
    } finally {
      // 无论成败都要把库开回来，否则后续读写都会卡在「已关闭」上。
      await DatabaseHelper.instance.database;
    }
  }

  Future<void> _deleteIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// List all backup files sorted by modification time (newest first)
  Future<List<FileSystemEntity>> listBackups() async {
    await ensureBackupDir();
    final dir = Directory(backupDir);
    final files = await dir.list().toList();
    // 逐个 await 取修改时间，再排序。
    //
    // 旧实现在 sort 比较器里调 statSync()：一次排序会触发 O(n log n) 次同步
    // 系统调用，全部阻塞在 UI isolate 上；备份文件多起来（上限 50 份）时
    // 打开备份列表会明显顿一下。
    final modified = <FileSystemEntity, DateTime>{};
    for (final file in files) {
      modified[file] = await _modifiedTime(file);
    }
    files.sort((a, b) => modified[b]!.compareTo(modified[a]!));
    return files;
  }

  /// 异步取实体修改时间（File 才有 `lastModified`，目录退化到 `stat`）。
  static Future<DateTime> _modifiedTime(FileSystemEntity entity) async {
    if (entity is File) return entity.lastModified();
    return (await entity.stat()).modified;
  }

  /// Restore from a backup file.
  ///
  /// 恢复是**整库替换**，所以顺序必须是：先把当前库留档 → 校验备份可用 →
  /// 关库 → 清掉 -wal/-shm → 覆盖 → 重开。任何一步失败都把原库放回去，
  /// 绝不会出现「恢复到一半，两边都不完整」。
  Future<bool> restoreBackup(String backupPath) async {
    final dbPath = DatabaseHelper.instance.dbPath;
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final previous = '$dbPath.before-restore-$stamp';

    // 1. 校验备份本身：打不开或完整性检查不过的直接拒绝，别拿坏文件去覆盖。
    if (!await _isUsableDatabase(backupPath)) {
      debugPrint('备份文件不可用，已取消恢复：$backupPath');
      return false;
    }

    bool hadPrevious = false;
    try {
      // 2. 当前库留档（关库后再复制，保证是落盘状态）。
      await DatabaseHelper.instance.closeDatabase();
      final current = File(dbPath);
      if (await current.exists()) {
        await current.copy(previous);
        hadPrevious = true;
      }
      await _deleteSidecars(dbPath);

      // 3. 覆盖并重开。
      await File(backupPath).copy(dbPath);
      await _deleteSidecars(dbPath);
      await DatabaseHelper.instance.database;
      await DatabaseHelper.instance.reloadAll();

      if (hadPrevious) {
        try {
          await File(previous).delete();
        } catch (_) {}
      }
      return true;
    } catch (e) {
      debugPrint('恢复备份失败，正在回滚：$e');
      // 4. 回滚：把刚才留档的原库放回去，尽量让用户回到恢复前的状态。
      try {
        await DatabaseHelper.instance.closeDatabase();
        await _deleteSidecars(dbPath);
        if (hadPrevious && await File(previous).exists()) {
          await File(previous).copy(dbPath);
          await _deleteSidecars(dbPath);
        }
      } catch (rollbackError) {
        debugPrint('回滚原库失败：$rollbackError');
      }
      try {
        await DatabaseHelper.instance.database;
      } catch (openError) {
        debugPrint('回滚后重开数据库失败：$openError');
      }
      return false;
    }
  }

  /// 备份文件是否是能打开、且完整性检查通过的真实数据库。
  Future<bool> _isUsableDatabase(String path) async {
    if (!await File(path).exists()) return false;
    Database? probe;
    try {
      probe = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final rows = await probe.rawQuery('PRAGMA integrity_check');
      if (rows.isEmpty) return false;
      return '${rows.first.values.first}'.toLowerCase() == 'ok';
    } catch (error) {
      debugPrint('校验备份失败：$path（$error）');
      return false;
    } finally {
      try {
        await probe?.close();
      } catch (_) {}
    }
  }

  /// 删掉主库旁的 -wal / -shm / -journal：整库替换时必须清干净，否则旧日志
  /// 会把刚换上的库改回损坏状态。
  Future<void> _deleteSidecars(String dbPath) async {
    for (final suffix in ['-wal', '-shm', '-journal']) {
      try {
        final file = File('$dbPath$suffix');
        if (await file.exists()) await file.delete();
      } catch (error) {
        debugPrint('清理 $suffix 失败：$error');
      }
    }
  }

  /// Delete all backup files
  Future<void> clearAllBackups() async {
    await ensureBackupDir();
    final dir = Directory(backupDir);
    final files = await dir.list().toList();
    for (final file in files) {
      await file.delete();
    }
  }

  /// Delete a specific backup file
  Future<void> deleteBackup(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _cleanupOldBackups() async {
    final dir = Directory(backupDir);
    if (!await dir.exists()) return;

    final files = await dir.list().toList();
    // 同 listBackups：不在排序比较器里做同步 stat。
    final modified = <FileSystemEntity, DateTime>{};
    for (final file in files) {
      modified[file] = await _modifiedTime(file);
    }
    files.sort((a, b) => modified[a]!.compareTo(modified[b]!));

    while (files.length > maxBackups) {
      await files.first.delete();
      files.removeAt(0);
    }
  }

  // ---- JSON Export/Import ----
  /// 导出整库为 JSON。
  ///
  /// 表数据从数据库读出来后，缩进美化编码放到后台 isolate：几万条记录的库
  /// 光 `JsonEncoder.withIndent` 就能吃掉上百毫秒的主 isolate 时间。
  Future<String> exportToJson() async {
    final db = await DatabaseHelper.instance.database;
    final data = <String, Object?>{
      'groups': await db.query('groups'),
      'students': await db.query('students'),
      'score_records': await db.query('score_records'),
      'course_schedule': await db.query('course_schedule'),
      'schedule_adjustment': await db.query('schedule_adjustment'),
      'export_time': DateTime.now().toIso8601String(),
    };
    return HeavyCompute.encodeJsonPretty(data);
  }

  /// 导入 JSON 快照。
  ///
  /// 整段导入放在**一个事务**里：以前是先逐表 delete 再逐行 insert，中途任何
  /// 一行数据不合法（缺字段、外键对不上）都会停在「已经清空、还没导完」的
  /// 状态，用户看到的就是数据全没了。现在要么全部生效，要么原样保留。
  Future<bool> importFromJson(String jsonStr) async {
    try {
      // 整库 JSON 的解码同样搬到后台 isolate。
      final data = await HeavyCompute.decodeJson(jsonStr) as Map<String, dynamic>;
      final db = await DatabaseHelper.instance.database;

      // Backup first
      await createBackup(force: true);

      // 导入顺序按外键依赖：组 → 学生 → 记录；其余表互不相关。
      const tables = <String>[
        'groups',
        'students',
        'score_records',
        'course_schedule',
        'schedule_adjustment',
      ];
      await db.transaction((txn) async {
        // 先清空（顺序与外键相反），再按依赖顺序写回。
        for (final table in tables.reversed) {
          await txn.delete(table);
        }
        for (final table in tables) {
          final rows = data[table];
          if (rows is! List) continue;
          for (final row in rows) {
            if (row is! Map) continue;
            final map = Map<String, dynamic>.from(row);
            map.remove('id'); // Let DB auto-assign
            await txn.insert(table, map);
          }
        }
      });

      await DatabaseHelper.instance.reloadAll();
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---- Reset Operations ----
  Future<void> resetScoreRecords() async {
    await createBackup(force: true);
    final db = await DatabaseHelper.instance.database;
    await db.delete('score_records');
    await DatabaseHelper.instance.reloadAll();
  }

  Future<void> resetGroups() async {
    await createBackup(force: true);
    final db = await DatabaseHelper.instance.database;
    await db.delete('score_records');
    await db.delete('students');
    await db.delete('groups');
    await DatabaseHelper.instance.reloadAll();
  }

  Future<void> resetAll() async {
    await createBackup(force: true);
    final db = await DatabaseHelper.instance.database;
    await db.delete('score_records');
    await db.delete('students');
    await db.delete('groups');
    await db.delete('course_schedule');
    await db.delete('schedule_adjustment');
    await DatabaseHelper.instance.reloadAll();
  }
}
