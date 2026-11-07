import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';

import 'server_db.dart';

/// 管理后台的配置。
class AdminConfig {
  const AdminConfig({this.enabled = true, this.allowRemote = false});

  /// 关掉之后 `/admin*` 一律 404（`--no-admin`）。
  final bool enabled;

  /// 默认只允许**回环来源**访问管理后台。
  ///
  /// 理由与 docs/sync-transport-security.md 一致：默认是明文 HTTP，
  /// 同一局域网内任何人都能嗅探。管理后台是高价值入口，不该默认对全网开放。
  ///
  /// 注意这**不是安全边界**：走反向代理时所有请求都表现为回环。
  /// 真正的边界是管理员 token。
  final bool allowRemote;
}

/// 管理员产生的事件挂在哪个 device_id 下。
///
/// 必须**不对应任何真实设备**：`_pull` 会排除请求者自己的 device_id，
/// 如果管理员借用某台真实设备的 id，那条事件就永远到不了那台设备。
/// 反过来，用一个独立 id 可以让**所有**设备都拉到管理员的改动。
const String kAdminDeviceId = 'srv_admin';

/// 会话有效期。固定 12 小时，不做滑动续期——
/// 续期会让"忘记关页面"变成永久有效令牌。
const Duration kAdminSessionTtl = Duration(hours: 12);

/// 登录失败限流（与配对码同构，但用独立的表）。
///
/// 管理员 token 有 256 位熵，穷举本身不现实；限流挡的是"日志里漏过一半
/// token 的猜测"和把服务端当靶子刷这类事，同时也是个告警信号。
const int kAdminMaxFailures = 10;
const Duration kAdminLockout = Duration(minutes: 15);

// ---- 管理员 token ----

/// 确保库里有一个管理员 token；**首次生成时返回明文**，之后返回 null。
///
/// 只打印一次是有意的：token 以 sha256 存储，丢了就只能轮换，
/// 这跟"库泄露也拿不到明文"是同一个决定的两面。
String? ensureAdminToken(Database db) {
  final rows = db.select('SELECT 1 FROM admins LIMIT 1');
  if (rows.isNotEmpty) return null;
  final token = randomToken();
  db.execute(
    'INSERT INTO admins(id, token_hash, created_at, rotated_at) '
    'VALUES (?, ?, ?, NULL)',
    ['admin', hashSecret(token), DateTime.now().toIso8601String()],
  );
  return token;
}

/// 轮换管理员 token，返回新的明文。旧 token 立即失效。
String rotateAdminToken(Database db) {
  final token = randomToken();
  final now = DateTime.now().toIso8601String();
  db.execute(
    'INSERT INTO admins(id, token_hash, created_at, rotated_at) '
    'VALUES (?, ?, ?, ?) '
    'ON CONFLICT(id) DO UPDATE SET token_hash = excluded.token_hash, '
    'rotated_at = excluded.rotated_at',
    ['admin', hashSecret(token), now, now],
  );
  // 轮换即吊销所有现有会话：换 token 的动机通常是"可能泄露了"，
  // 这时候留着旧会话等于没换。
  db.execute('DELETE FROM admin_sessions');
  return token;
}

/// 校验管理员 token（恒定时间比较由哈希查表本身承担：
/// 攻击者拿到库也只有哈希，且 sha256 的查表不泄露部分匹配）。
bool verifyAdminToken(Database db, String token) {
  if (token.isEmpty) return false;
  final rows = db.select('SELECT token_hash FROM admins WHERE id = ?', ['admin']);
  if (rows.isEmpty) return false;
  return rows.first['token_hash'] == hashSecret(token);
}

// ---- 会话 ----

/// 签发一个会话 token（返回明文，库里只存哈希）。
String createAdminSession(Database db) {
  final token = randomToken();
  final now = DateTime.now();
  db.execute(
    'INSERT OR REPLACE INTO admin_sessions(token_hash, created_at, expires_at, '
    'last_seen_at) VALUES (?, ?, ?, ?)',
    [
      hashSecret(token),
      now.toIso8601String(),
      now.add(kAdminSessionTtl).toIso8601String(),
      now.toIso8601String(),
    ],
  );
  return token;
}

/// 会话是否有效；有效时顺手刷新 last_seen_at。
bool touchAdminSession(Database db, String token) {
  if (token.isEmpty) return false;
  final hash = hashSecret(token);
  final rows = db.select(
    'SELECT expires_at FROM admin_sessions WHERE token_hash = ?',
    [hash],
  );
  if (rows.isEmpty) return false;
  final expires = DateTime.tryParse(rows.first['expires_at'] as String);
  if (expires == null || DateTime.now().isAfter(expires)) {
    // 过期就顺手删掉，避免表里堆着永远不会再用到的行。
    db.execute('DELETE FROM admin_sessions WHERE token_hash = ?', [hash]);
    return false;
  }
  db.execute(
    'UPDATE admin_sessions SET last_seen_at = ? WHERE token_hash = ?',
    [DateTime.now().toIso8601String(), hash],
  );
  return true;
}

void deleteAdminSession(Database db, String token) {
  if (token.isEmpty) return;
  db.execute('DELETE FROM admin_sessions WHERE token_hash = ?', [
    hashSecret(token),
  ]);
}

// ---- 登录失败限流 ----

void recordAdminLoginFailure(Database db, String source) {
  final rows = db.select(
    'SELECT attempt_count, locked_until FROM admin_login_failures '
    'WHERE source = ?',
    [source],
  );
  var count = 1;
  DateTime? lockedUntil;
  if (rows.isNotEmpty) {
    count = (rows.first['attempt_count'] as int) + 1;
    final text = rows.first['locked_until'] as String?;
    if (text != null) lockedUntil = DateTime.tryParse(text);
  }
  if (count >= kAdminMaxFailures) {
    lockedUntil = DateTime.now().add(kAdminLockout);
    count = 0;
  }
  db.execute(
    'INSERT OR REPLACE INTO admin_login_failures(source, attempt_count, '
    'locked_until) VALUES (?, ?, ?)',
    [source, count, lockedUntil?.toIso8601String()],
  );
}

void clearAdminLoginFailures(Database db, String source) {
  db.execute('DELETE FROM admin_login_failures WHERE source = ?', [source]);
}

bool isAdminLoginLocked(Database db, String source) {
  final rows = db.select(
    'SELECT locked_until FROM admin_login_failures WHERE source = ?',
    [source],
  );
  if (rows.isEmpty) return false;
  final text = rows.first['locked_until'] as String?;
  if (text == null) return false;
  final until = DateTime.tryParse(text);
  if (until == null) return false;
  return DateTime.now().isBefore(until);
}

// ---- 审计 ----

/// 记一条管理操作。
///
/// 上一轮安全问题里有一条"服务端没有审计日志，出事无法追溯"。
/// 管理后台正好是唯一需要人工介入的写入口，因此这里把 before/after
/// 都记下来——它是"管理员改坏了什么"唯一的事后证据。
void writeAudit(
  Database db, {
  required String action,
  String? tbl,
  String? uid,
  Object? before,
  Object? after,
  String? sourceIp,
  String actor = 'admin',
}) {
  db.execute(
    'INSERT INTO admin_audit(ts, actor, action, tbl, uid, before, after, '
    'source_ip) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    [
      DateTime.now().toIso8601String(),
      actor,
      action,
      tbl,
      uid,
      before == null ? null : jsonEncode(before),
      after == null ? null : jsonEncode(after),
      sourceIp,
    ],
  );
}

/// 请求来源的 IP（取不到时返回 'unknown'）。
String clientIp(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is HttpConnectionInfo) return info.remoteAddress.address;
  return request.headers['host'] ?? 'unknown';
}

/// 是否来自回环地址。
///
/// 取不到连接信息时**放行**：这种情况只会出现在测试/中间件场景，
/// 而"取不到就当外网"会把后台锁死在反向代理后面，反而更糟。
/// 真实边界见 [AdminConfig.allowRemote] 的注释。
bool isLoopbackRequest(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is! HttpConnectionInfo) return true;
  return info.remoteAddress.isLoopback;
}
