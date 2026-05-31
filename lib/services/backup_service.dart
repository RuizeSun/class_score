import 'dart:convert';
import 'dart:io';
import '../database/database_helper.dart';
import 'package:path/path.dart' as p;

class BackupService {
  static final BackupService instance = BackupService._();
  BackupService._();

  static const int maxBackups = 50;

  String get backupDir {
    return p.join(DatabaseHelper.instance.dbDir, '..', 'backups');
  }

  Future<void> ensureBackupDir() async {
    final dir = Directory(backupDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// Create a full database backup as a copy of the SQLite file
  Future<String?> createBackup() async {
    try {
      await ensureBackupDir();
      final dbPath = DatabaseHelper.instance.dbPath;
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final backupPath = p.join(backupDir, 'backup_$timestamp.db');

      // Close the database first to ensure consistency
      await DatabaseHelper.instance.closeDatabase();

      // Copy the file
      await File(dbPath).copy(backupPath);

      // Reopen the database
      await DatabaseHelper.instance.database;

      // Cleanup old backups
      await _cleanupOldBackups();

      return backupPath;
    } catch (e) {
      // Try to reopen database if something went wrong
      await DatabaseHelper.instance.database;
      return null;
    }
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
      await createBackup();

      // Clear existing data (in reverse order of foreign keys)
      await db.delete('score_records');
      await db.delete('students');
      await db.delete('groups');
      await db.delete('course_schedule');

      // Import groups
      if (data['groups'] != null) {
        for (final row in data['groups'] as List) {
          final map = Map<String, dynamic>.from(row as Map);
          map.remove('id'); // Let DB auto-assign
          await db.insert('groups', map);
        }
      }

      // Import students
      if (data['students'] != null) {
        for (final row in data['students'] as List) {
          final map = Map<String, dynamic>.from(row as Map);
          map.remove('id');
          await db.insert('students', map);
        }
      }

      // Import score_records
      if (data['score_records'] != null) {
        for (final row in data['score_records'] as List) {
          final map = Map<String, dynamic>.from(row as Map);
          map.remove('id');
          await db.insert('score_records', map);
        }
      }

      // Import course_schedule
      if (data['course_schedule'] != null) {
        for (final row in data['course_schedule'] as List) {
          final map = Map<String, dynamic>.from(row as Map);
          map.remove('id');
          await db.insert('course_schedule', map);
        }
      }

      await DatabaseHelper.instance.reloadAll();
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---- Reset Operations ----
  Future<void> resetScoreRecords() async {
    await createBackup();
    final db = await DatabaseHelper.instance.database;
    await db.delete('score_records');
    await DatabaseHelper.instance.reloadAll();
  }

  Future<void> resetGroups() async {
    await createBackup();
    final db = await DatabaseHelper.instance.database;
    await db.delete('score_records');
    await db.delete('students');
    await db.delete('groups');
    await DatabaseHelper.instance.reloadAll();
  }

  Future<void> resetAll() async {
    await createBackup();
    final db = await DatabaseHelper.instance.database;
    await db.delete('score_records');
    await db.delete('students');
    await db.delete('groups');
    await db.delete('course_schedule');
    await DatabaseHelper.instance.reloadAll();
  }
}
