import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_migration_v11.dart';

/// 绕过同步触发器的批量写。
///
/// 触发器把**每一次** insert/update/delete 都记一笔到 outbox，这对日常操作
/// 是优点（绝不漏记），但对"整库级"操作是灾难：导入 500 个学生就会产生
/// 500 + 500 条事件（导入 + 收尾的 reloadAll），重置/导入还会把同步列一起清掉。
///
/// 这里提供两条口子：
/// 1. [suppressed]：临时把 `applying` 标记打开，触发器在此期间不记账
///    （与"应用远端事件"复用同一个开关，语义一致：**这不是一次用户编辑**）；
/// 2. [preserveSyncColumns]：导入时把 uid / rev / rev_device 一起带上，
///    让"从备份恢复"不会把设备身份搞成两份不同 uid。
class SyncWriteGuard {
  const SyncWriteGuard._();

  /// 在 [action] 执行期间关闭事件捕获。
  ///
  /// 注意：这些写操作**不会**被同步。用于导入/重置/备份还原——
  /// 它们的结果由"下一次全量对齐"承担，而不是由事件流承担。
  ///
  /// **收尾必须补 uid**：suppressed 期间 INSERT 触发器被 WHEN 关掉，新行拿到
  /// 的是 NULL uid。而 AFTER UPDATE 触发器会 `INSERT INTO sync_outbox ...
  /// SELECT r.uid`，uid 为 NULL 直接撞 `sync_outbox.uid NOT NULL` ——
  /// 表现为"恢复备份之后，老师改任何一个名字都抛异常"。
  /// 补齐必须在 `applying` 仍为 '1' 时做，否则这条 UPDATE 自己就会触发它。
  static Future<T> suppressed<T>(
    Database db,
    Future<T> Function() action,
  ) async {
    await db.execute("UPDATE sync_state SET value = '1' WHERE key = 'applying'");
    try {
      final result = await action();
      await SyncMigrationV11.backfillMissingUids(db);
      return result;
    } finally {
      await db.execute(
        "UPDATE sync_state SET value = '0' WHERE key = 'applying'",
      );
    }
  }

  /// 导入一行时，把同步列合并进 [row]。
  ///
  /// [source] 是备份文件里的原始行。若它带 uid，就沿用（同一份数据在另一台
  /// 设备上仍然指向同一个 uid）；否则交给触发器生成。
  static Map<String, dynamic> preserveSyncColumns(
    Map<String, dynamic> row,
    Map<String, dynamic>? source,
  ) {
    if (source == null) return row;
    final out = Map<String, dynamic>.from(row);
    for (final key in const ['uid', 'rev', 'rev_device', 'updated_at']) {
      if (source[key] != null) out[key] = source[key];
    }
    return out;
  }
}
