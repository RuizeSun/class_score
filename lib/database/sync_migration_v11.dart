import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v11 迁移：同步元数据 + outbox 捕获触发器。
///
/// 设计说明见 docs/sync-schema-v11.md。要点：
/// 1. 六张业务表各加 uid / rev / rev_device / deleted_at / updated_at；
/// 2. 三个触发器把任何写入路径（含事务、含未来新代码）自动记账到 outbox；
/// 3. 删除改成墓碑（BEFORE DELETE + RAISE(IGNORE)），物理行保留。
///
/// 为什么不在每个写方法里手写记账：db.insert/update/delete 在 lib/ 里有 52 处
/// 调用，漏一处就会产生永远不会同步的幽灵数据，而且只有真同步一次才会暴露。
class SyncMigrationV11 {
  const SyncMigrationV11._();

  /// 执行迁移。必须在外层事务里调用（见 DatabaseHelper._onUpgrade / _onCreate）。
  static Future<void> run(Database db) async {
    // recursive_triggers=ON 时，AFTER INSERT 里的 UPDATE 会被再记一次账并直接
    // 爆递归上限（实测 too many levels of trigger recursion）。
    // 迁移开始时显式关掉，等于把这条隐式依赖写死。
    await db.execute('PRAGMA recursive_triggers = OFF');

    await _createMetaTables(db);
    // 先重建 app_settings：它原本没有自增 id，而同步元数据要靠 id 定位。
    // 必须在补列之前做，否则重建会把刚加的列冲掉。
    await _rebuildAppSettings(db);
    for (final spec in syncTableSpecs) {
      await _addColumns(db, spec.name);
      await _backfill(db, spec);
      // app_settings 的主键是 key 而不是 id，触发器要按 key 定位，
      // 而且只认白名单里的键 —— 它的触发器单独建（见下）。
      if (spec.name == 'app_settings') continue;
      await _createTriggers(db, spec);
    }
    await _relaxUniqueIndexes(db);
    await _createSettingsTriggers(db);
  }

  /// 把「整列唯一」的唯一索引改成「只约束活着的行」。
  ///
  /// 墓碑行仍然留在表里，如果唯一索引还把它算进去，会出现两个真实故障：
  /// 1. 学生删掉后学号 07 永远不能再分配（新建学生直接抛 UNIQUE 失败）；
  /// 2. 覆盖导入先删旧行再插新行，新行沿用同一学号 → 每一条都失败，
  ///    而导入循环里的 catch 会把异常吞掉，表现为"一条都没导进去"。
  ///
  /// 用部分索引（`WHERE deleted_at IS NULL`）把墓碑排除在唯一性之外。
  static const Map<String, ({String index, String column})> _uniqueIndexes = {
    'students': (index: 'idx_student_number', column: 'student_number'),
    'schedule_adjustment': (
      index: 'idx_schedule_adjustment_date',
      column: 'date',
    ),
    // app_settings 的 key 同理：某个设置键的墓碑不能挡住新值。
    'app_settings': (index: 'idx_app_settings_key', column: 'key'),
  };

  static Future<void> _relaxUniqueIndexes(Database db) async {
    for (final entry in _uniqueIndexes.entries) {
      final table = entry.key;
      final spec = entry.value;
      await db.execute('DROP INDEX IF EXISTS ${spec.index}');
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS ${spec.index} '
        'ON $table(${spec.column}) WHERE deleted_at IS NULL',
      );
    }
  }

  static Future<void> _createMetaTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_uid_map (
        tbl TEXT NOT NULL,
        uid TEXT NOT NULL,
        local_id INTEGER NOT NULL,
        PRIMARY KEY (tbl, uid)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        tbl TEXT NOT NULL,
        uid TEXT NOT NULL,
        op TEXT NOT NULL,
        payload TEXT NOT NULL,
        rev INTEGER NOT NULL,
        rev_device TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_outbox_tbl ON sync_outbox(tbl)',
    );
    await db.execute(
      'INSERT OR IGNORE INTO sync_state(key, value) VALUES '
      "('lamport', '0'), ('device_id', ''), ('server_seq', '0'), "
      "('applying', '0')",
    );
  }

  /// 给所有同步表补齐缺失的 uid。
  ///
  /// 迁移时跑一次，此后由 [SyncWriteGuard.suppressed] 在每次"整库级写入"收尾时
  /// 再跑一次——suppressed 期间 INSERT 触发器不记账，新行拿到的 uid 是 NULL。
  ///
  /// **只在 `applying = '1'` 时调用**（或迁移事务内）：否则这条 UPDATE 会自己
  /// 触发 AFTER UPDATE 记账，凭空产生一批事件。
  ///
  /// 白名单外的设置键**故意不补**：没 uid 的行 snapshotLocalRows 会跳过，
  /// 这是"pin_hash 不上传"的第二道保险。
  static Future<void> backfillMissingUids(Database db) async {
    for (final spec in syncTableSpecs) {
      final onlySynced = spec.name == 'app_settings';
      final allowed = syncedSettingKeys.map((k) => "'$k'").join(', ');
      await db.execute(
        'UPDATE ${spec.name} '
        "SET uid = '${spec.uidPrefix}_' || lower(hex(randomblob(8))) "
        "WHERE (uid IS NULL OR uid = '')"
        '${onlySynced ? ' AND key IN ($allowed)' : ''}',
      );
    }
  }

  static Future<void> _addColumns(Database db, String table) async {
    // ALTER TABLE ADD COLUMN 不支持 IF NOT EXISTS，重复执行会抛错，
    // 所以先用 PRAGMA 探测列是否已存在。
    final existing = await db.rawQuery('PRAGMA table_info($table)');
    final names = existing.map((r) => r['name'] as String).toSet();
    if (!names.contains('uid')) {
      await db.execute('ALTER TABLE $table ADD COLUMN uid TEXT');
    }
    if (!names.contains('rev')) {
      await db.execute(
        'ALTER TABLE $table ADD COLUMN rev INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!names.contains('rev_device')) {
      await db.execute(
        "ALTER TABLE $table ADD COLUMN rev_device TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!names.contains('deleted_at')) {
      await db.execute('ALTER TABLE $table ADD COLUMN deleted_at TEXT');
    }
    // updated_at 只用于排错与「最后修改时间」展示，不参与冲突决议。
    if (!names.contains('updated_at')) {
      await db.execute('ALTER TABLE $table ADD COLUMN updated_at TEXT');
    }
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_${table}_uid '
      'ON $table(uid) WHERE uid IS NOT NULL',
    );
  }

  /// 历史数据补齐 uid。uid 不承载业务语义，因此**不写 outbox**
  /// （否则升级当天会凭空多出几千条待推送事件）。
  ///
  /// `app_settings` 只补白名单里的键：这张表混着外观/安全/本机行为，
  /// 给 pin_hash 之类的行也补 uid 会让它们变成"可被快照上传的历史数据"
  /// （首次会合走的是 snapshotLocalRows，那条路径不看触发器）。
  /// 没补 uid 的行 snapshotLocalRows 会跳过，多一层保险。
  static Future<void> _backfill(Database db, SyncTableSpec spec) async {
    final onlySynced = spec.name == 'app_settings';
    final allowed = syncedSettingKeys.map((k) => "'$k'").join(', ');
    await db.execute(
      'UPDATE ${spec.name} '
      "SET uid = '${spec.uidPrefix}_' || lower(hex(randomblob(8))) "
      "WHERE (uid IS NULL OR uid = '')"
      '${onlySynced ? ' AND key IN ($allowed)' : ''}',
    );
  }

  static Future<void> _createTriggers(Database db, SyncTableSpec spec) async {
    final t = spec.name;
    final payload = _payloadOf(spec, 'r');
    await db.execute('DROP TRIGGER IF EXISTS ${t}_sync_ai');
    await db.execute('DROP TRIGGER IF EXISTS ${t}_sync_au');
    await db.execute('DROP TRIGGER IF EXISTS ${t}_sync_bd');

    // INSERT：补 uid 与取号必须在**同一条 UPDATE** 里完成。
    // 若拆成两条，第一条只改 uid（rev 不变）会满足 AFTER UPDATE 的
    // "NEW.rev <= OLD.rev" 条件，导致同一次插入被记两笔账（实测）。
    await db.execute('''
      CREATE TRIGGER ${t}_sync_ai AFTER INSERT ON $t
      WHEN (SELECT value FROM sync_state WHERE key = 'applying') = '0'
      BEGIN
        UPDATE sync_state SET value =
          CASE WHEN CAST(value AS INTEGER) >= $maxSafeRev
               THEN CAST(value AS TEXT)          -- 已到上限：不再 +1，防 REAL 退化
               ELSE CAST(CAST(value AS INTEGER) + 1 AS TEXT)
          END
         WHERE key = 'lamport';
        UPDATE $t
           SET uid = COALESCE(NULLIF(NEW.uid, ''),
                              '${spec.uidPrefix}_' || lower(hex(randomblob(8)))),
               rev = (SELECT CAST(value AS INTEGER) FROM sync_state
                       WHERE key = 'lamport'),
               rev_device = (SELECT value FROM sync_state WHERE key = 'device_id'),
               updated_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')
         WHERE id = NEW.id;
        INSERT INTO sync_outbox(tbl, uid, op, payload, rev, rev_device, created_at)
        SELECT '$t', r.uid, 'upsert', $payload,
               r.rev, r.rev_device,
               strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')
          FROM $t r WHERE r.id = NEW.id;
      END
    ''');

    // 条件 NEW.rev <= OLD.rev：同步写回时 rev 已被抬到远端版本，不重复记账，
    // 否则服务端下发的事件会被本地再次推送，形成打环。
    await db.execute('''
      CREATE TRIGGER ${t}_sync_au AFTER UPDATE ON $t
      WHEN NEW.rev <= OLD.rev
       AND (SELECT value FROM sync_state WHERE key = 'applying') = '0'
      BEGIN
        UPDATE sync_state SET value =
          CASE WHEN CAST(value AS INTEGER) >= $maxSafeRev
               THEN CAST(value AS TEXT)          -- 已到上限：不再 +1，防 REAL 退化
               ELSE CAST(CAST(value AS INTEGER) + 1 AS TEXT)
          END
         WHERE key = 'lamport';
        UPDATE $t
           SET rev = (SELECT CAST(value AS INTEGER) FROM sync_state
                       WHERE key = 'lamport'),
               rev_device = (SELECT value FROM sync_state WHERE key = 'device_id'),
               updated_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')
         WHERE id = NEW.id;
        INSERT INTO sync_outbox(tbl, uid, op, payload, rev, rev_device, created_at)
        SELECT '$t', r.uid, 'upsert', $payload,
               r.rev, r.rev_device,
               strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')
          FROM $t r WHERE r.id = NEW.id;
      END
    ''');

    // SQLite 没有「把 DELETE 变成 UPDATE」的语法：先打墓碑再 RAISE(IGNORE)
    // 中止这条 DELETE，行就留下来了。副作用是 db.delete() 返回 0 行。
    await db.execute('''
      CREATE TRIGGER ${t}_sync_bd BEFORE DELETE ON $t
      WHEN (SELECT value FROM sync_state WHERE key = 'applying') = '0'
      BEGIN
        UPDATE sync_state SET value =
          CASE WHEN CAST(value AS INTEGER) >= $maxSafeRev
               THEN CAST(value AS TEXT)          -- 已到上限：不再 +1，防 REAL 退化
               ELSE CAST(CAST(value AS INTEGER) + 1 AS TEXT)
          END
         WHERE key = 'lamport';
        UPDATE $t
           SET deleted_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'),
               rev = (SELECT CAST(value AS INTEGER) FROM sync_state
                       WHERE key = 'lamport'),
               rev_device = (SELECT value FROM sync_state WHERE key = 'device_id')
         WHERE id = OLD.id;
        INSERT INTO sync_outbox(tbl, uid, op, payload, rev, rev_device, created_at)
        SELECT '$t', r.uid, 'delete', $payload,
               r.rev, r.rev_device,
               strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')
          FROM $t r WHERE r.id = OLD.id;
        SELECT RAISE(IGNORE);
      END
    ''');
  }

  /// 把 app_settings 补齐成 `id + key UNIQUE`。
  ///
  /// 同步元数据要靠自增 id 定位一行，而这张表原本以 key 为主键（没有 id）。
  /// SQLite 不能直接改主键，只能重建表；表里只有几十行，代价可忽略。
  /// 不这么做的话，应用远端设置时会在执行 `WHERE id = ?` 时直接 SQL 报错。
  static Future<void> _rebuildAppSettings(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(app_settings)');
    final names = columns.map((r) => r['name'] as String).toSet();
    if (names.contains('id')) return; // 已经是新结构
    await db.execute('''
      CREATE TABLE app_settings_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        uid TEXT,
        rev INTEGER NOT NULL DEFAULT 0,
        rev_device TEXT NOT NULL DEFAULT '',
        deleted_at TEXT,
        updated_at TEXT
      )
    ''');
    // 只搬业务列：同步列（uid/rev/...）此时还没加上，
    // 紧接着的 _addColumns + _backfill 会给它们补默认值。
    await db.execute(
      'INSERT INTO app_settings_new(key, value) SELECT key, value FROM app_settings',
    );
    await db.execute('DROP TABLE app_settings');
    await db.execute('ALTER TABLE app_settings_new RENAME TO app_settings');
  }

  /// app_settings 的触发器：**只对白名单里的键**记账。
  ///
  /// 这张表混着两类东西：影响算分的配置（要同步）和本机外观（绝不能同步）。
  /// 用 WHEN 子句把白名单写死在这里，比在 Dart 侧过滤更稳：漏掉一处过滤
  /// 就会让主题色跟着跑到别人机器上，而这几乎不可能被人发现。
  static Future<void> _createSettingsTriggers(Database db) async {
    const t = 'app_settings';
    final allowed = syncedSettingKeys.map((k) => "'$k'").join(', ');
    await db.execute('DROP TRIGGER IF EXISTS ${t}_sync_ai');
    await db.execute('DROP TRIGGER IF EXISTS ${t}_sync_au');
    await db.execute('DROP TRIGGER IF EXISTS ${t}_sync_bd');
    await db.execute('''
      CREATE TRIGGER ${t}_sync_ai AFTER INSERT ON $t
      WHEN NEW.key IN ($allowed)
       AND (SELECT value FROM sync_state WHERE key = 'applying') = '0'
      BEGIN
        UPDATE sync_state SET value =
          CASE WHEN CAST(value AS INTEGER) >= $maxSafeRev
               THEN CAST(value AS TEXT)          -- 已到上限：不再 +1，防 REAL 退化
               ELSE CAST(CAST(value AS INTEGER) + 1 AS TEXT)
          END
         WHERE key = 'lamport';
        UPDATE $t
           SET uid = COALESCE(NULLIF(NEW.uid, ''),
                              'set_' || lower(hex(randomblob(8)))),
               rev = (SELECT CAST(value AS INTEGER) FROM sync_state
                       WHERE key = 'lamport'),
               rev_device = (SELECT value FROM sync_state WHERE key = 'device_id'),
               updated_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')
         WHERE key = NEW.key;
        INSERT INTO sync_outbox(tbl, uid, op, payload, rev, rev_device, created_at)
        SELECT '$t', r.uid, 'upsert',
               json_object('key', r.key, 'value', r.value),
               r.rev, r.rev_device,
               strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')
          FROM $t r WHERE r.key = NEW.key;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER ${t}_sync_au AFTER UPDATE ON $t
      WHEN NEW.key IN ($allowed)
       AND NEW.rev <= OLD.rev
       AND (SELECT value FROM sync_state WHERE key = 'applying') = '0'
      BEGIN
        UPDATE sync_state SET value =
          CASE WHEN CAST(value AS INTEGER) >= $maxSafeRev
               THEN CAST(value AS TEXT)          -- 已到上限：不再 +1，防 REAL 退化
               ELSE CAST(CAST(value AS INTEGER) + 1 AS TEXT)
          END
         WHERE key = 'lamport';
        UPDATE $t
           SET rev = (SELECT CAST(value AS INTEGER) FROM sync_state
                       WHERE key = 'lamport'),
               rev_device = (SELECT value FROM sync_state WHERE key = 'device_id'),
               updated_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')
         WHERE key = NEW.key;
        INSERT INTO sync_outbox(tbl, uid, op, payload, rev, rev_device, created_at)
        SELECT '$t', r.uid, 'upsert',
               json_object('key', r.key, 'value', r.value),
               r.rev, r.rev_device,
               strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')
          FROM $t r WHERE r.key = NEW.key;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER ${t}_sync_bd BEFORE DELETE ON $t
      WHEN OLD.key IN ($allowed)
       AND (SELECT value FROM sync_state WHERE key = 'applying') = '0'
      BEGIN
        UPDATE sync_state SET value =
          CASE WHEN CAST(value AS INTEGER) >= $maxSafeRev
               THEN CAST(value AS TEXT)          -- 已到上限：不再 +1，防 REAL 退化
               ELSE CAST(CAST(value AS INTEGER) + 1 AS TEXT)
          END
         WHERE key = 'lamport';
        UPDATE $t
           SET deleted_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'),
               rev = (SELECT CAST(value AS INTEGER) FROM sync_state
                       WHERE key = 'lamport'),
               rev_device = (SELECT value FROM sync_state WHERE key = 'device_id')
         WHERE key = OLD.key;
        INSERT INTO sync_outbox(tbl, uid, op, payload, rev, rev_device, created_at)
        SELECT '$t', r.uid, 'delete',
               json_object('key', r.key, 'value', r.value),
               r.rev, r.rev_device,
               strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')
          FROM $t r WHERE r.key = OLD.key;
        SELECT RAISE(IGNORE);
      END
    ''');
  }

  /// 单行 → JSON payload。
  ///
  /// 外键列在这里**原样输出本地 id**，翻译成 uid 在 Dart 侧做
  /// （见 lib/sync/sync_event_codec.dart）：在 SQLite 里跨表关联拼 JSON 会让
  /// 触发器不可读，而且拉取方向也需要一份对称的逻辑。
  static String _payloadOf(SyncTableSpec spec, String alias) {
    final parts = spec.columns.map((c) => "'$c', $alias.$c");
    return 'json_object(${parts.join(', ')})';
  }
}
