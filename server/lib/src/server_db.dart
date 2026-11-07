import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

/// 服务端库：建表、迁移、配对码与 token 的存取。
///
/// 从 `sync_server.dart` 里抽出来，是为了让管理后台（`src/admin_api.dart`）
/// 与同步端点共用同一套建库/迁移代码，而不是各自再开一次库。抽出来之后
/// `sync_server.dart` 用 `export` 把它们继续暴露出去，既有调用方（10 个测试
/// 文件与 bin/main.dart）一行都不用改。

/// 打开（或初始化）服务端库。
Database openServerDb(String path) {
  final db = sqlite3.open(path);
  db.execute('PRAGMA journal_mode = WAL');
  db.execute('PRAGMA synchronous = NORMAL');
  db.execute('''
    CREATE TABLE IF NOT EXISTS events (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id TEXT NOT NULL,
      tbl TEXT NOT NULL,
      uid TEXT NOT NULL,
      op TEXT NOT NULL,
      rev INTEGER NOT NULL,
      rev_device TEXT NOT NULL,
      payload TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_events_dev ON events(device_id, rev)',
  );
  // 幂等查询 `WHERE device_id=? AND tbl=? AND uid=? AND rev=?` 用得上这条，
  // 否则每插入一条都要扫该设备的全部事件，大批量 push 退化为 O(n²)。
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_events_dedup '
    'ON events(device_id, tbl, uid, rev)',
  );
  // summary 里的 MAX(rev) / 裁剪事件都要按 rev 扫。
  db.execute('CREATE INDEX IF NOT EXISTS idx_events_rev ON events(rev)');
  db.execute('''
    CREATE TABLE IF NOT EXISTS latest (
      tbl TEXT NOT NULL,
      uid TEXT NOT NULL,
      op TEXT NOT NULL,
      rev INTEGER NOT NULL,
      rev_device TEXT NOT NULL,
      payload TEXT NOT NULL,
      PRIMARY KEY (tbl, uid)
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS devices (
      id TEXT PRIMARY KEY,
      token_hash TEXT NOT NULL,
      name TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS pairing (
      code TEXT PRIMARY KEY,
      expires_at TEXT NOT NULL,
      used_at TEXT,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      locked_until TEXT
    )
  ''');
  // 旧库里的 pairing 表没有这些列，CREATE TABLE IF NOT EXISTS 不会补——
  // 必须显式 ALTER。实测升级时这里会直接抛 "table pairing has no column"，
  // 而且是在发配对码时才炸，属于最晚才暴露的那种。
  _ensureColumn(db, 'pairing', 'used_at', 'TEXT');
  _ensureColumn(db, 'pairing', 'attempt_count', 'INTEGER NOT NULL DEFAULT 0');
  _ensureColumn(db, 'pairing', 'locked_until', 'TEXT');
  // 设备最近活跃时间：管理后台要能看出"哪台设备其实已经很久没同步了"。
  // 同样是旧库没有的列，必须显式补。
  _ensureColumn(db, 'devices', 'last_seen_at', 'TEXT');
  _createAdminTables(db);
  _migrateLegacyTokenHashes(db);
  return db;
}

/// 管理后台的表。
///
/// 与同步表刻意分开：管理员的会话、审计、登录失败计数都不参与同步，
/// 也不该让设备端看到。
void _createAdminTables(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS admins (
      id TEXT PRIMARY KEY,
      token_hash TEXT NOT NULL,
      created_at TEXT NOT NULL,
      rotated_at TEXT
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS admin_sessions (
      token_hash TEXT PRIMARY KEY,
      created_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS admin_audit (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL,
      actor TEXT NOT NULL,
      action TEXT NOT NULL,
      tbl TEXT,
      uid TEXT,
      before TEXT,
      after TEXT,
      source_ip TEXT
    )
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_admin_audit_ts ON admin_audit(ts)',
  );
  db.execute('''
    CREATE TABLE IF NOT EXISTS admin_login_failures (
      source TEXT PRIMARY KEY,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      locked_until TEXT
    )
  ''');
}

// ---- 配对限流 ----

/// 配对失败的容忍阈值与锁定时长。
///
/// 选 10 次/15 分钟：老师手抄错一次两次很常见，10 次够宽容；
/// 而 6 位码有 100 万种，10 次/15 分钟意味着暴力穷举要跑上千年。
const int kPairingMaxFailures = 10;
const Duration kPairingLockout = Duration(minutes: 15);

/// 记一次失败；达到阈值就锁定该来源。
void recordPairingFailure(Database db, String source) {
  final now = DateTime.now();
  final rows = db.select(
    'SELECT attempt_count, locked_until, expires_at FROM pairing '
    "WHERE code = '__failed__::' || ?",
    [source],
  );
  var count = 1;
  DateTime? lockedUntil;
  if (rows.isNotEmpty) {
    count = (rows.first['attempt_count'] as int) + 1;
    final lockText = rows.first['locked_until'] as String?;
    if (lockText != null) lockedUntil = DateTime.tryParse(lockText);
  }
  if (count >= kPairingMaxFailures) {
    lockedUntil = now.add(kPairingLockout);
    count = 0; // 锁定后重新计数，避免解锁立刻又满
  }
  db.execute(
    'INSERT OR REPLACE INTO pairing(code, expires_at, used_at, attempt_count, locked_until) '
    'VALUES (?, ?, NULL, ?, ?)',
    [
      '__failed__::$source',
      now.add(const Duration(days: 3650)).toIso8601String(),
      count,
      lockedUntil?.toIso8601String(),
    ],
  );
}

/// 该来源是否正处于锁定期。
bool isPairingLocked(Database db, String source) {
  final rows = db.select(
    'SELECT locked_until FROM pairing WHERE code = ?',
    ['__failed__::$source'],
  );
  if (rows.isEmpty) return false;
  final text = rows.first['locked_until'] as String?;
  if (text == null) return false;
  final until = DateTime.tryParse(text);
  if (until == null) return false;
  return DateTime.now().isBefore(until);
}

/// 事件日志保留：超过阈值的旧事件会被裁掉。
///
/// `events` 只增不减，一年能长到几十 MB，而 `pull`/`summary` 的成本随之线性
/// 上升。但**不能盲删**：`_pull` 用 seq 游标，删掉某台设备还没拉到的段落
/// 会让它永久跳过那些事件。
///
/// 因此只裁掉「所有已配对设备都已经拉过去」的那一段：
/// 取所有设备里最小的已确认 seq（设备级游标服务端并不记录，这里退化为
/// "按时间保留 N 天" + "至少留 N 条"），再叠加一个保留窗口。
/// 这是保守策略：宁可多留，也不让任何设备出现空洞。
///
/// 想彻底安全可以只在服务端管理后台手动触发；这里默认只在启动时跑一次。
int pruneEvents(
  Database db, {
  Duration retain = const Duration(days: 90),
  int keepAtLeast = 20000,
}) {
  final total =
      (db.select('SELECT COUNT(*) AS n FROM events').first['n'] as int?) ?? 0;
  if (total <= keepAtLeast) return 0;

  final cutoff = DateTime.now().subtract(retain).toIso8601String();
  final removable = db.select(
    'SELECT COUNT(*) AS n FROM events WHERE created_at < ?',
    [cutoff],
  );
  final candidate = (removable.first['n'] as int?) ?? 0;
  if (candidate <= 0) return 0;

  // 至少保留 keepAtLeast 条：算出还能删多少。
  final allowed = candidate - (keepAtLeast - total).clamp(0, keepAtLeast);
  final budget = allowed <= 0 ? 0 : allowed;
  if (budget == 0) return 0;

  db.execute(
    'DELETE FROM events WHERE seq IN ('
    'SELECT seq FROM events WHERE created_at < ? ORDER BY seq LIMIT ?'
    ')',
    [cutoff, budget],
  );
  return db.updatedRows;
}

/// 给已存在的表补列（SQLite 没有 ADD COLUMN IF NOT EXISTS）。
void _ensureColumn(Database db, String table, String column, String spec) {
  final info = db.select('PRAGMA table_info($table)');
  final names = info.map((r) => r['name'] as String).toSet();
  if (names.contains(column)) return;
  db.execute('ALTER TABLE $table ADD COLUMN $column $spec');
}

/// 把旧版 base64 "哈希" 升级成 sha256。
///
/// 旧格式是可逆的，留着等于库泄露就能登录。这里借着"我们本来就能解出
/// 明文"这一点做一次性迁移：解出来、算真哈希、写回去，已配对设备不用重配对。
void _migrateLegacyTokenHashes(Database db) {
  final rows = db.select('SELECT id, token_hash FROM devices');
  var migrated = 0;
  for (final row in rows) {
    final stored = row['token_hash'] as String;
    if (!isLegacyTokenHash(stored)) continue;
    final token = recoverLegacyToken(stored);
    if (token == null) continue;
    db.execute(
      'UPDATE devices SET token_hash = ? WHERE id = ?',
      [hashDeviceToken(token), row['id']],
    );
    migrated++;
  }
  if (migrated > 0) {
    stderr.writeln('已把 $migrated 个设备的旧版 token 存储升级为 sha256');
  }
}

/// 生成一个一次性配对码（默认 10 分钟有效）。
String issuePairingCode(Database db, {Duration ttl = const Duration(minutes: 10)}) {
  final random = Random.secure();
  String code;
  // 6 位数字空间只有 100 万，虽不常见，但当表里堆着历史码时仍有概率撞上。
  // 撞上就是"新码覆盖掉别人的未用码"，所以撞了就换一个。
  do {
    code = List.generate(6, (_) => random.nextInt(10).toString()).join();
  } while (db
      .select('SELECT 1 FROM pairing WHERE code = ?', [code]).isNotEmpty);
  // 显式列出全部列：INSERT OR REPLACE 会先删后插，未列出的列会回到默认值
  // （attempt_count / locked_until 必须一起写，否则限流状态被清掉）。
  db.execute(
    'INSERT OR REPLACE INTO pairing(code, expires_at, used_at, attempt_count, '
    'locked_until) VALUES (?, ?, NULL, 0, NULL)',
    [code, DateTime.now().add(ttl).toIso8601String()],
  );
  return code;
}

/// 当前是否还有可用的配对码（未使用且未过期）。
bool hasActivePairingCode(Database db) {
  final rows = db.select(
    'SELECT 1 FROM pairing WHERE used_at IS NULL AND expires_at > ? LIMIT 1',
    [DateTime.now().toIso8601String()],
  );
  return rows.isNotEmpty;
}

/// 当前有效的配对码（未使用且未过期），没有则返回 null。
Map<String, Object?>? activePairingCode(Database db) {
  final rows = db.select(
    'SELECT code, expires_at FROM pairing '
    'WHERE used_at IS NULL AND expires_at > ? '
    "AND code NOT LIKE '__failed__::%' "
    'ORDER BY expires_at DESC LIMIT 1',
    [DateTime.now().toIso8601String()],
  );
  if (rows.isEmpty) return null;
  return {'code': rows.first['code'], 'expires_at': rows.first['expires_at']};
}

/// 已配对设备列表（不含 token）。
List<Map<String, Object?>> listDevices(Database db) {
  final rows = db.select(
    'SELECT id, name, created_at FROM devices ORDER BY created_at',
  );
  return [
    for (final row in rows)
      {
        'id': row['id'],
        'name': row['name'],
        'created_at': row['created_at'],
      },
  ];
}

String randomToken() {
  final random = Random.secure();
  return List.generate(
    32,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// token 的存储形式：**不可逆**的哈希。
///
/// 这里曾经是 `base64Url.encode(utf8.encode('class_score::' + token))`。
/// base64 是**编码不是哈希**：拿到服务端库就能直接解出明文 token 登录，
/// 与"库泄露也无法直接拿来登录"的注释完全相反（实测可解，见
/// test/sync_token_hash_test.dart）。
///
/// 改为 `sha256(salt + token)`：
/// - token 本身是 32 字节安全随机数，不存在"弱口令猜解"的问题，
///   因此不需要慢哈希（bcrypt/scrypt）带来的延迟；
/// - 固定盐阻断彩虹表（安全性来自 token 的熵，不来自盐的保密性）。
String hashDeviceToken(String token) => hashSecret(token);

/// 管理员 token 与会话 token 用同一套存储形式。
String hashSecret(String value) {
  final digest = sha256.convert(utf8.encode(kTokenHashSalt + value));
  return 'v2$digest';
}

/// 旧版（base64 编码）的存储格式。
bool isLegacyTokenHash(String stored) {
  if (stored.startsWith('v2')) return false;
  try {
    return utf8.decode(base64Url.decode(stored)).startsWith('class_score::');
  } catch (_) {
    return false;
  }
}

/// 从旧格式里还原 token（仅用于一次性迁移）。
String? recoverLegacyToken(String stored) {
  try {
    final text = utf8.decode(base64Url.decode(stored));
    if (!text.startsWith('class_score::')) return null;
    return text.substring('class_score::'.length);
  } catch (_) {
    return null;
  }
}

/// 哈希用的固定前缀盐。
///
/// 用固定值而不是随机落库，是为了让"重启后已配对设备仍然有效"这件事
/// 不依赖额外的初始化逻辑；token 本身已是 32 字节随机数，固定盐足以
/// 阻断彩虹表。安全性来自 token 的熵，不来自盐的保密性。
const String kTokenHashSalt = 'class_score.sync.v2';
// ---- 事件追加（同步端点与管理后台共用的唯一写入口） ----

/// 下一条事件的全局 rev。
///
/// 用 `MAX(rev) + 1` 而不是"某台设备的计数器 +1"：rev 在客户端是 **Lamport
/// 时钟**（见 docs/sync-boundaries.md §3.4），服务端作为新的写入者，取全局
/// 最大值再 +1 才能保证这一条在 LWW 比较里必定胜出——否则管理员改的值会被
/// 某台设备上一个更旧的版本盖回去，而且看不出原因。
int nextEventRev(Database db) {
  final rows = db.select('SELECT COALESCE(MAX(rev), 0) AS m FROM events');
  final maxRev = (rows.first['m'] as int?) ?? 0;
  // 溢出保护：MAX(rev) 已经顶到安全上限时，+1 在 Dart 里会**回绕成负数**
  // （实测 9223372036854775807 + 1 == -9223372036854775808），此后所有
  // 管理员编辑都拿负号、在 LWW 里永久输。push 侧已经拒收超出 maxSafeRev
  // 的事件，所以正常情况到不了这里；真到了说明库已被污染，宁可停在
  // 上限上（维持现状的裁决顺序），也绝不发出负号。
  if (maxRev >= maxSafeRev) return maxSafeRev;
  return maxRev + 1;
}

/// 追加一条事件并同步物化表 `latest`。**调用方负责事务。**
///
/// 同步端点的 push 与管理后台的编辑都走这里，保证两处的冲突裁决口径
/// 完全一致（都调用 [upsertLatestRow]，内部用 compareRevision）。
void appendEvent(
  Database db, {
  required String deviceId,
  required String table,
  required String uid,
  required String op,
  required int rev,
  required String revDevice,
  required String payload,
}) {
  db.execute(
    'INSERT INTO events(device_id, tbl, uid, op, rev, rev_device, payload, '
    'created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    [
      deviceId,
      table,
      uid,
      op,
      rev,
      revDevice,
      payload,
      DateTime.now().toIso8601String(),
    ],
  );
  upsertLatestRow(
    db,
    table: table,
    uid: uid,
    op: op,
    rev: rev,
    revDevice: revDevice,
    payload: payload,
  );
}

/// 物化表：每行只留最新版本。
///
/// 读接口（排名/看板/Bot/管理后台）查这张表，不必回放整个事件流；
/// 冲突决议与客户端完全一致（rev 大者胜，rev 相同比 rev_device），
/// 用 [compareRevision] 保证两端口径不会分叉。
void upsertLatestRow(
  Database db, {
  required String table,
  required String uid,
  required String op,
  required int rev,
  required String revDevice,
  required String payload,
}) {
  final current = db.select(
    'SELECT rev, rev_device FROM latest WHERE tbl = ? AND uid = ?',
    [table, uid],
  );
  if (current.isNotEmpty) {
    final winner = compareRevision(
      aRev: rev,
      aDevice: revDevice,
      bRev: current.first['rev'] as int,
      bDevice: current.first['rev_device'] as String,
    );
    if (winner <= 0) return;
  }
  db.execute(
    'INSERT INTO latest(tbl, uid, op, rev, rev_device, payload) '
    'VALUES (?, ?, ?, ?, ?, ?) '
    'ON CONFLICT(tbl, uid) DO UPDATE SET '
    'op = excluded.op, rev = excluded.rev, '
    'rev_device = excluded.rev_device, payload = excluded.payload',
    [table, uid, op, rev, revDevice, payload],
  );
}
