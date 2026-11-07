import 'dart:convert';
import 'dart:io';

import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import 'src/admin_api.dart';
import 'src/admin_auth.dart';
import 'src/server_db.dart';

// 建库、配对码、token 哈希这些原本都在本文件里。抽到 src/server_db.dart
// 是为了让管理后台共用同一份（它也要建表、也要发配对码）。这里 re-export
// 保持既有 import 不变：10 个测试文件与 bin/main.dart 都只认这个入口。
export 'src/admin_api.dart' show AdminApi;
export 'src/admin_auth.dart';
export 'src/admin_assets.g.dart';
export 'src/server_db.dart';

/// class_score 同步服务端。
///
/// 职责刻意收得很窄：**收事件、按 seq 发事件、维护一份物化副本**。
/// 业务规则（分值范围、周期）全部留在客户端，服务端只做"能不能收"的判断，
/// 这样 App 与服务端不会长出两套各自的"真相"。
/// 单次 push 的事件条数上限。客户端 pushBatch = 200，这里留足余量，
/// 但必须有上限：`readAsString()` 是无界的，没有这道门单请求能吃完内存。
const int kMaxPushEvents = 1000;

/// 请求体上限（10 MB）。一次 push 200 条事件远小于此。
const int kMaxBodyBytes = 10 * 1024 * 1024;

class SyncServer {
  SyncServer(this._db);

  final Database _db;

  Router get router {
    return Router()
      ..get(SyncPaths.health, _health)
      ..post(SyncPaths.pair, _pair)
      ..post(SyncPaths.push, _push)
      ..get(SyncPaths.pull, _pull)
      ..get(SyncPaths.bootstrap, _bootstrap)
      ..get(SyncPaths.summary, _summary);
  }

  Response _health(Request request) =>
      _json({'ok': true, 'protocol': syncProtocolVersion});

  // ---- 配对 ----

  /// 用一次性配对码换设备 token。
  ///
  /// 配对码由服务端启动时打印，单次有效、默认 10 分钟过期——足够老师把
  /// 地址和码抄到另一台机器上，又不至于被人随手捡走。
  Future<Response> _pair(Request request) async {
    final body = await _readJson(request);
    if (body == null) return _badRequest('invalid json');
    final code = (body['code'] as String?)?.trim() ?? '';
    final deviceId = (body['device_id'] as String?)?.trim() ?? '';
    if (code.isEmpty || deviceId.isEmpty) return _badRequest('code required');

    // 管理员产生的事件挂在 srv_admin 名下（见 kAdminDeviceId 的注释：
    // 它必须不对应任何真实设备，否则那台设备永远拉不到管理员改动）。
    // 如果允许设备用这个前缀注册，任何人都能"成为管理员设备"，
    // 进而让真正的管理员事件对这台设备不可见。
    if (deviceId.startsWith('srv_')) {
      return _badRequest('reserved device id prefix');
    }

    // 配对码是 6 位数字，理论上可以穷举。这里按**来源 IP** 限流：
    // 同一个来源连续失败达到阈值后锁定一段时间，锁定期内一律拒绝。
    // 没有这层，脚本几小时就能把整个号码空间走一遍。
    final source = _clientKey(request);
    if (isPairingLocked(_db, source)) {
      return Response(
        429,
        body: jsonEncode({'error': 'too many attempts, retry later'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // 配对码永远是 6 位数字，先做形状校验。
    //
    // 这不只是"顺手校验"：限流用的失败计数行也写在这张表里，code 是
    // `__failed__::<来源IP>`，且 used_at=NULL / expires_at=+3650 天。
    // 下面那条 SQL 是"按 code 精确匹配"，如果不排除这些哨兵行，
    // 任何人只要先故意输错一次，就能把 `__failed__::<自己的IP>` 当成
    // 配对码换到一个有效设备 token —— 完全跳过真正的配对码。
    // （实测：输错一次后 POST /pair {"code":"__failed__::127.0.0.1"} → 200 + token）
    if (!_isPairingCodeShape(code)) {
      recordPairingFailure(_db, source);
      return _unauthorized();
    }

    final rows = _db.select(
      'SELECT expires_at, used_at, attempt_count FROM pairing '
      "WHERE code = ? AND code NOT LIKE '\\_\\_failed\\_\\_::%' ESCAPE '\\'",
      [code],
    );
    if (rows.isEmpty) {
      recordPairingFailure(_db, source);
      return _unauthorized();
    }
    final row = rows.first;
    if (row['used_at'] != null) {
      recordPairingFailure(_db, source);
      return _unauthorized();
    }
    if (DateTime.now().isAfter(DateTime.parse(row['expires_at'] as String))) {
      recordPairingFailure(_db, source);
      return _unauthorized();
    }

    final token = randomToken();
    final now = DateTime.now().toIso8601String();
    _db.execute('BEGIN');
    try {
      _db.execute(
        'INSERT OR REPLACE INTO devices(id, token_hash, name, created_at, '
        'last_seen_at) VALUES (?, ?, ?, ?, ?)',
        [
          deviceId,
          hashSecret(token),
          (body['name'] as String?) ?? '',
          now,
          now,
        ],
      );
      _db.execute('UPDATE pairing SET used_at = ? WHERE code = ?', [now, code]);
      _db.execute('COMMIT');
    } catch (error) {
      _db.execute('ROLLBACK');
      return _serverError('$error');
    }
    return _json({'token': token, 'device_id': deviceId});
  }

  // ---- 推送 ----

  /// 接收一批事件。
  ///
  /// 幂等键是 `(device_id, tbl, uid, rev)`：客户端重试同一批事件不会重复入库。
  Future<Response> _push(Request request) async {
    final device = request.context['device'] as String?;
    if (device == null) return _unauthorized();

    final body = await _readJson(request);
    if (body == null) return _badRequest('invalid json');
    final raw = (body['events'] as List?) ?? const [];
    if (raw.isEmpty) {
      return _json({'accepted': 0, 'duplicates': 0, 'seq': _maxSeq()});
    }

    if (raw.length > kMaxPushEvents) {
      return _badRequest('too many events in one batch (max $kMaxPushEvents)');
    }

    var accepted = 0;
    var duplicates = 0;
    var rejected = 0;
    // 逐条 SAVEPOINT：一条坏事件不能把整批回滚掉。
    //
    // 之前整批只有一个事务，任何一条 payload 让它抛错（未知表名、字段类型
    // 不对、rev 非法）就 500 + ROLLBACK；而客户端 `_push` 遇错直接抛异常、
    // 无限重试**同一批**，于是这一批永远推不上去，outbox 永不排空。
    // 现在坏的那条单独跳过（计入 rejected 并在应答里返回），好的照常入库。
    _db.execute('BEGIN');
    try {
      for (final item in raw) {
        try {
          final event = SyncEvent.fromJson(
            (item as Map).cast<String, dynamic>(),
          );
          // 只接受协议里声明过的表：否则设备能推 `tbl='students2'`，
          // 在 latest 里留下任何界面都看不到的僵尸行。
          if (syncTableSpec(event.table) == null) {
            rejected++;
            continue;
          }
          // rev 必须在安全范围内：见 maxSafeRev 的注释。拒收而非钳制——
          // 收下一条 rev=2^63 的"正常数据"，等于让这台设备的所有后续写入
          // 在 LWW 里永久压过其它设备与管理员（全局取号会立即溢出）。
          if (!isSafeRev(event.rev)) {
            rejected++;
            continue;
          }
          final seen = _db.select(
            'SELECT 1 FROM events WHERE device_id = ? AND tbl = ? AND uid = ? AND rev = ?',
            [device, event.table, event.uid, event.rev],
          );
          if (seen.isNotEmpty) {
            duplicates++;
            continue;
          }
          final payload = jsonEncode(event.data ?? const {});
          // revDevice 只用于 LWW 平局裁决与"事件来自哪台设备"的展示，
          // 但允许设备冒充 'srv_admin' 会让审计与"管理员改的"这件事失真
          // （配对时只挡了 device_id，没挡 rev_device）。
          final revDevice =
              event.revDevice.startsWith('srv_') ? device : event.revDevice;
          // 物化表的更新走 appendEvent → upsertLatestRow：管理后台的编辑
          // 也走同一个函数，保证两边冲突裁决口径不会分叉。
          _db.execute('SAVEPOINT push_event');
          try {
            appendEvent(
              _db,
              deviceId: device,
              table: event.table,
              uid: event.uid,
              op: event.op.wire,
              rev: event.rev,
              revDevice: revDevice,
              payload: payload,
            );
            _db.execute('RELEASE push_event');
            accepted++;
          } catch (_) {
            _db.execute('ROLLBACK TO push_event');
            _db.execute('RELEASE push_event');
            rejected++;
          }
        } catch (_) {
          // 连 SyncEvent.fromJson 都过不去（畸形 JSON / 缺字段）。
          rejected++;
        }
      }
      _db.execute('COMMIT');
    } catch (error) {
      _db.execute('ROLLBACK');
      return _serverError('$error');
    }
    return _json({
      'accepted': accepted,
      'duplicates': duplicates,
      'rejected': rejected,
      'seq': _maxSeq(),
    });
  }

  // ---- 拉取 ----

  /// 按 seq 增量下发，**排除来源设备自己的事件**。
  ///
  /// 这是防打环的第二道保险：第一道在客户端（触发器看到 `applying` 就不记账），
  /// 但历史上线顺序不可控，服务端这一层必须独立兜住。
  Response _pull(Request request) {
    final device = request.context['device'] as String?;
    if (device == null) return _unauthorized();

    final since = int.tryParse(request.url.queryParameters['since'] ?? '0') ?? 0;
    final limit =
        (int.tryParse(request.url.queryParameters['limit'] ?? '500') ?? 500)
            .clamp(1, 1000);

    final rows = _db.select(
      'SELECT seq, tbl, uid, op, rev, rev_device, payload FROM events '
      'WHERE seq > ? AND device_id <> ? ORDER BY seq ASC LIMIT ?',
      [since, device, limit + 1],
    );
    final hasMore = rows.length > limit;
    final page = hasMore ? rows.sublist(0, limit) : rows;
    return _json({
      'events': page.map(_rowToJson).toList(),
      'seq': page.isEmpty ? since : page.last['seq'] as int,
      'has_more': hasMore,
    });
  }

  /// 全量快照：给"新设备接管 / 服务端重建"用。
  ///
  /// 只回每行的最新状态，不回事件历史——客户端要的是当前值，
  /// 一次性传几千条历史事件没有任何收益。
  Response _bootstrap(Request request) {
    final device = request.context['device'] as String?;
    if (device == null) return _unauthorized();
    // latest 表没有 seq（它只存最新状态，不参与游标），这里显式补 0。
    final rows = _db.select(
      'SELECT 0 AS seq, tbl, uid, op, rev, rev_device, payload FROM latest',
    );
    return _json({
      'events': rows.map(_rowToJson).toList(),
      'seq': _maxSeq(),
    });
  }

  /// 轻量摘要：客户端首次配对时用它判断"服务端是不是空的"。
  ///
  /// 只回计数与最大 rev，不下发内容——判断"要不要初始上传"不需要内容，
  /// 而内容可能有几 MB。
  Response _summary(Request request) {
    final device = request.context['device'] as String?;
    if (device == null) return _unauthorized();

    final tables = <String, Map<String, Object?>>{};
    for (final spec in syncTableSpecs) {
      final live = _db.select(
        'SELECT COUNT(*) AS n FROM latest WHERE tbl = ? AND op <> ?',
        [spec.name, 'delete'],
      );
      tables[spec.name] = {'live': (live.first['n'] as int?) ?? 0};
    }
    final events =
        (_db.select('SELECT COUNT(*) AS n FROM events').first['n'] as int?) ?? 0;
    final maxRev =
        (_db.select('SELECT COALESCE(MAX(rev), 0) AS m FROM events').first['m']
            as int?) ??
        0;
    return _json({
      'protocol': syncProtocolVersion,
      'tables': tables,
      'event_count': events,
      'max_rev': maxRev,
      'max_seq': _maxSeq(),
    });
  }

  Map<String, dynamic> _rowToJson(Row row) {
    return SyncEvent(
      table: row['tbl'] as String,
      uid: row['uid'] as String,
      op: SyncOp.fromWire(row['op'] as String),
      rev: row['rev'] as int,
      revDevice: row['rev_device'] as String,
      data: (jsonDecode(row['payload'] as String) as Map).cast<String, dynamic>(),
      seq: row['seq'] as int,
    ).toJson();
  }

  int _maxSeq() =>
      (_db.select('SELECT COALESCE(MAX(seq), 0) AS s FROM events').first['s']
          as int?) ??
      0;

  Future<Map<String, dynamic>?> _readJson(Request request) async {
    try {
      // 必须有上限：readAsString() 会把整个请求体读进内存，
      // 一个几 GB 的请求就能把服务端打挂。
      final declared = request.contentLength;
      if (declared != null && declared > kMaxBodyBytes) return null;
      var total = 0;
      final chunks = <int>[];
      await for (final chunk in request.read()) {
        total += chunk.length;
        if (total > kMaxBodyBytes) return null;
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return null;
      final text = utf8.decode(chunks);
      if (text.isEmpty) return null;
      return (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  // ---- 应答 ----

  Response _json(Object body) => Response.ok(
    jsonEncode(body),
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Response _badRequest(String message) => Response(
    400,
    body: jsonEncode({'error': message}),
    headers: {'content-type': 'application/json'},
  );

  Response _unauthorized() => Response(
    401,
    body: jsonEncode({'error': 'unauthorized'}),
    headers: {'content-type': 'application/json'},
  );

  Response _serverError(String message) => Response(
    500,
    body: jsonEncode({'error': message}),
    headers: {'content-type': 'application/json'},
  );
}

/// 启动同步服务。
///
/// **强烈建议启用 TLS。** 不启用时，配对码与设备 token 都以明文在网络上传输：
/// token 一旦被同一局域网内的任何人看到，就能冒充这台设备推送任意数据
/// （因为服务端只靠 Bearer token 鉴权，没有别的绑定）。
///
/// 传了 [securityContext] 就走 HTTPS；否则仍然是明文 HTTP，并在启动时
/// 打印一条警告（见 bin/main.dart）。
///
/// [admin] 控制内置管理后台（`/admin`）。关掉时这些路径返回 404。
Future<HttpServer> serveSync({
  required Database db,
  String host = '0.0.0.0',
  int port = 8787,
  SecurityContext? securityContext,
  AdminConfig admin = const AdminConfig(),
}) async {
  final server = SyncServer(db);
  final adminApi = AdminApi(db, allowRemote: admin.allowRemote);

  // 路由拼装：`/admin` 子树交给管理后台，其余仍归同步端点。
  // 两条链路在中间件里就分开鉴权（设备 token vs 管理员会话），
  // 因此这里只需要按前缀分流一次。
  Future<Response> dispatch(Request request) {
    final path = request.url.path;
    final isAdminPath = path == 'admin' || path.startsWith('admin/');
    if (isAdminPath) {
      if (!admin.enabled) {
        return Future.value(
          Response.notFound('admin console disabled', headers: {
            'content-type': 'text/plain; charset=utf-8',
          }),
        );
      }
      return adminApi.router.call(request);
    }
    return server.router.call(request);
  }

  final handler = const Pipeline()
      .addMiddleware(_adminGuard(db, admin))
      .addMiddleware(_authMiddleware(db))
      .addMiddleware(logRequests())
      .addHandler(dispatch);

  return shelf_io.serve(
    handler,
    host,
    port,
    securityContext: securityContext,
  );
}

/// 管理后台的鉴权与来源限制。
///
/// 与设备鉴权分开：设备走 Bearer 设备 token，后台走 Bearer 会话 token，
/// 两者查不同的表、有不同的有效期。合在一起写迟早会把一行设备 token
/// 当成管理员凭证放进去。
Middleware _adminGuard(Database db, AdminConfig config) {
  return (inner) => (request) {
    final path = request.url.path;
    final isAdminPath = path == 'admin' || path.startsWith('admin/');
    if (!isAdminPath) return inner(request);
    if (!config.enabled) {
      return Response.notFound('admin console disabled');
    }
    // 默认只允许回环来源。理由见 docs/sync-transport-security.md：
    // 默认是明文 HTTP，管理后台不该对同网段所有人开放。
    if (!config.allowRemote && !isLoopbackRequest(request)) {
      return Response(
        403,
        body: jsonEncode({'error': 'admin console is loopback-only'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // 登录与静态资源不需要会话；其余一律要。
    final p = path;
    final openPath =
        p == 'admin/api/login' || p == 'admin' || p == 'admin/' ||
        p == 'admin/admin.css' || p == 'admin/admin.js';
    if (openPath) return inner(request);

    final header = request.headers['authorization'] ?? '';
    if (!header.toLowerCase().startsWith('bearer ')) {
      return Response(
        401,
        body: jsonEncode({'error': 'unauthorized'}),
        headers: {'content-type': 'application/json'},
      );
    }
    final token = header.substring(7).trim();
    if (!touchAdminSession(db, token)) {
      return Response(
        401,
        body: jsonEncode({'error': 'unauthorized'}),
        headers: {'content-type': 'application/json'},
      );
    }
    return inner(request.change(context: {'admin': 'admin'}));
  };
}

/// 配对码的合法形状：正好 6 位数字。
///
/// 见 [_pair] 里的注释：`pairing` 表同时存着限流用的哨兵行
/// （`__failed__::<IP>`），必须有办法把"真码"和"哨兵行"区分开。
bool _isPairingCodeShape(String code) =>
    code.length == 6 && RegExp(r'^\d{6}$').hasMatch(code);

String _clientKey(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is HttpConnectionInfo) return info.remoteAddress.address;
  return request.headers['host'] ?? 'unknown';
}

/// 设备鉴权。
///
/// 管理后台的路径在这里直接放行（它已经被 [_adminGuard] 处理过）：
/// 否则管理会话 token 会被拿去查 devices 表，必然 401。
Middleware _authMiddleware(Database db) {
  return (inner) => (request) {
    final path = request.url.path;
    if (path == 'admin' || path.startsWith('admin/')) return inner(request);
    if (path == 'health' || path == 'pair') return inner(request);

    // 协议版本必须校验。
    //
    // protocol.dart 里写着"服务端会拒绝版本不一致的客户端"，但此前服务端
    // 从不读这个 header —— 客户端发、服务端不认，版本漂移时客户端会拿到
    // 一堆解析不了的事件（`d`/`x` 字段改名之类），表现为"同步正常但没数据"。
    // 现在明确拒绝，让用户看到"需要升级"而不是一个安静的空转。
    final version = int.tryParse(request.headers['x-sync-protocol'] ?? '');
    if (version != null && version != syncProtocolVersion) {
      return Response(
        426,
        body: jsonEncode({
          'error': 'protocol mismatch',
          'server_protocol': syncProtocolVersion,
          'client_protocol': version,
        }),
        headers: {'content-type': 'application/json'},
      );
    }
    final header = request.headers['authorization'] ?? '';
    if (!header.toLowerCase().startsWith('bearer ')) {
      return Response(401, body: jsonEncode({'error': 'unauthorized'}));
    }
    final token = header.substring(7).trim();
    final rows = db.select('SELECT id FROM devices WHERE token_hash = ?', [
      hashSecret(token),
    ]);
    if (rows.isEmpty) {
      return Response(401, body: jsonEncode({'error': 'unauthorized'}));
    }
    final deviceId = rows.first['id'] as String;
    _touchDevice(db, deviceId);
    return inner(request.change(context: {'device': deviceId}));
  };
}

/// 记录设备最近活跃时间。
///
/// 每次请求都写一次库没有必要（心跳是 60 秒一次，多台设备同时在线时
/// 那些 UPDATE 纯属浪费），因此这里做 60 秒节流。
void _touchDevice(Database db, String deviceId) {
  try {
    final rows = db.select('SELECT last_seen_at FROM devices WHERE id = ?', [
      deviceId,
    ]);
    if (rows.isNotEmpty) {
      final last = rows.first['last_seen_at'] as String?;
      if (last != null) {
        final at = DateTime.tryParse(last);
        if (at != null &&
            DateTime.now().difference(at) < const Duration(seconds: 60)) {
          return;
        }
      }
    }
    db.execute('UPDATE devices SET last_seen_at = ? WHERE id = ?', [
      DateTime.now().toIso8601String(),
      deviceId,
    ]);
  } catch (_) {
    // 活跃时间只是运维信息，写失败不该影响同步本身。
  }
}
