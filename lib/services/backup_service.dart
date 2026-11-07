import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../database/database_helper.dart';
import '../database/sync_write_guard.dart';
import 'package:path/path.dart' as p;

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
    files.sort((a, b) {
      final statA = a.statSync();
      final statB = b.statSync();
      return statB.modified.compareTo(statA.modified);
    });
    return files;
  }

  /// Restore from a backup file
  Future<bool> restoreBackup(String backupPath) async {
    try {
      final dbPath = DatabaseHelper.instance.dbPath;

      // Close current database
      await DatabaseHelper.instance.closeDatabase();

      // Copy backup over current database
      await File(backupPath).copy(dbPath);

      // Reopen database (will trigger onCreate check)
      await DatabaseHelper.instance.database;
      await DatabaseHelper.instance.reloadAll();

      return true;
    } catch (e) {
      await DatabaseHelper.instance.database;
      return false;
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
    files.sort((a, b) {
      final statA = a.statSync();
      final statB = b.statSync();
      return statA.modified.compareTo(statB.modified);
    });

    while (files.length > maxBackups) {
      await files.first.delete();
      files.removeAt(0);
    }
  }

  // ---- JSON Export/Import ----
  Future<String> exportToJson() async {
    final db = await DatabaseHelper.instance.database;
    final data = {
      'groups': await db.query('groups'),
      'students': await db.query('students'),
      'score_records': await db.query('score_records'),
      'course_schedule': await db.query('course_schedule'),
      'schedule_adjustment': await db.query('schedule_adjustment'),
      'export_time': DateTime.now().toIso8601String(),
    };
    final encoder = const JsonEncoder.withIndent('  ');
    return encoder.convert(data);
  }

  Future<bool> importFromJson(String jsonStr) async {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final db = await DatabaseHelper.instance.database;

      // Backup first
      await createBackup(force: true);

      // 整库覆盖不是"用户逐条编辑"：在 suppressed 区间内执行，outbox 不会
      // 涌进几千条事件（否则恢复一次备份 = 推送一次全库）。副作用是这批
      // 写入不会被同步——恢复备份本身就是"以本地为准"，语义上成立。
      return await SyncWriteGuard.suppressed(db, () async {
        // 清空旧数据（suppressed 期间 BEFORE DELETE 触发器不生效，
        // 因此这里是**物理删除**，不会留下满库墓碑）。
        await db.delete('score_records');
        await db.delete('students');
        await db.delete('groups');
        await db.delete('course_schedule');
        await db.delete('schedule_adjustment');

        Future<void> importRows(String key, String table) async {
          final rows = data[key];
          if (rows is! List) return;
          for (final row in rows) {
            final source = Map<String, dynamic>.from(row as Map);
            final map = Map<String, dynamic>.from(source);
            map.remove('id'); // 让本地重新分配自增 id
            map.remove('deleted_at');
            // 备份里带了 uid / rev：沿用它们，这样"恢复备份"不会把同一份
            // 数据变成另一批 uid（否则对端会看到一堆新增 + 一堆删除）。
            await db.insert(
              table,
              SyncWriteGuard.preserveSyncColumns(map, source),
            );
          }
        }

        await importRows('groups', 'groups');
        await importRows('students', 'students');
        await importRows('score_records', 'score_records');
        await importRows('course_schedule', 'course_schedule');
        await importRows('schedule_adjustment', 'schedule_adjustment');
        return true;
      }).then((_) async {
        await DatabaseHelper.instance.reloadAll();
        return true;
      });
    } catch (e) {
      return false;
    }
  }

  // ---- Reset Operations ----
  /// 清空全部评分记录。
  ///
  /// 走 suppressed：整库级重置不该产生"每条记录一条删除事件"，
  /// 也不该在同步场景下留下一整批墓碑让对端跟着删一遍。
  Future<void> resetScoreRecords() async {
    await createBackup(force: true);
    final db = await DatabaseHelper.instance.database;
    await SyncWriteGuard.suppressed(db, () async {
      await db.delete('score_records');
    });
    await DatabaseHelper.instance.reloadAll();
  }

  Future<void> resetGroups() async {
    await createBackup(force: true);
    final db = await DatabaseHelper.instance.database;
    await SyncWriteGuard.suppressed(db, () async {
      await db.delete('score_records');
      await db.delete('students');
      await db.delete('groups');
    });
    await DatabaseHelper.instance.reloadAll();
  }

  Future<void> resetAll() async {
    await createBackup(force: true);
    final db = await DatabaseHelper.instance.database;
    await SyncWriteGuard.suppressed(db, () async {
      await db.delete('score_records');
      await db.delete('students');
      await db.delete('groups');
      await db.delete('course_schedule');
      await db.delete('schedule_adjustment');
    });
    await DatabaseHelper.instance.reloadAll();
  }
}
