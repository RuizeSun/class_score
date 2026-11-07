import 'dart:convert';

import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import 'admin_assets.g.dart';
import 'admin_auth.dart';
import 'server_db.dart';

/// 管理后台的 HTTP 接口。
///
/// 这是**面向服务端维护者**的接口，不是教师端，也不是业务写入口：
/// - 读：概览、设备、每张同步表的最新行、审计；
/// - 写：只允许"改已有行的安全列"，且必定追加一条同步事件。
///
/// 最重要的一条设计约束：**绝不直接改 `latest`**。`latest` 是派生表，
/// 直接改它会得到"服务端看着改了、所有设备永远不知道"的脱同步，而且
/// 没有任何界面能发现它。所有编辑都走 [appendEvent]，与设备推送同一条通路。
class AdminApi {
  AdminApi(this._db, {this.allowRemote = false});

  final Database _db;
  final bool allowRemote;

  Router get router {
    return Router()
      ..get('/admin', _index)
      ..get('/admin/', _index)
      ..get('/admin/admin.css', _asset('admin.css'))
      ..get('/admin/admin.js', _asset('admin.js'))
      ..post('/admin/api/login', _login)
      ..post('/admin/api/logout', _logout)
      ..get('/admin/api/overview', _overview)
      ..get('/admin/api/devices', _devices)
      ..delete('/admin/api/devices/<id>', _revokeDevice)
      ..get('/admin/api/pairing', _pairing)
      ..post('/admin/api/pairing', _newPairing)
      ..get('/admin/api/table/<name>', _table)
      ..patch('/admin/api/table/<name>/<uid>', _edit)
      ..get('/admin/api/audit', _audit);
  }

  // ---- 静态资源 ----

  Response _index(Request request) => _assetResponse('index.html');

  Handler _asset(String name) => (Request request) => _assetResponse(name);

  Response _assetResponse(String name) {
    final bytes = adminAssets[name];
    if (bytes == null) return _notFound();
    return Response.ok(
      bytes,
      headers: {
        'content-type': adminAssetMime(name),
        // 数据来自已配对设备，等同不可信输入。禁止内联脚本/样式，
        // 也就禁掉了"payload 里塞一段 <script>"这种注入。
        'content-security-policy':
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            "object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'cache-control': 'no-store',
      },
    );
  }

  // ---- 登录 ----

  /// 用管理员 token 换一个会话 token。
  ///
  /// 为什么不直接拿管理员 token 当 Bearer：浏览器要把它存进 localStorage，
  /// 而长期令牌落盘的风险和"设备 token 落盘"是一样的。会话是短期、可吊销的。
  Future<Response> _login(Request request) async {
    final source = clientIp(request);
    if (isAdminLoginLocked(_db, source)) {
      return _json({'error': 'too many attempts, retry later'}, status: 429);
    }
    final body = await _readJson(request);
    final token = (body?['token'] as String?)?.trim() ?? '';
    if (!verifyAdminToken(_db, token)) {
      recordAdminLoginFailure(_db, source);
      return _json({'error': 'unauthorized'}, status: 401);
    }
    clearAdminLoginFailures(_db, source);
    final session = createAdminSession(_db);
    writeAudit(
      _db,
      action: 'login',
      sourceIp: source,
    );
    return _json({
      'session': session,
      'expires_in': kAdminSessionTtl.inSeconds,
    });
  }

  Response _logout(Request request) {
    final token = _bearer(request);
    if (token != null) {
      deleteAdminSession(_db, token);
      writeAudit(_db, action: 'logout', sourceIp: clientIp(request));
    }
    return _json({'ok': true});
  }

  // ---- 概览 ----

  Response _overview(Request request) {
    int count(String sql) =>
        (_db.select(sql).first.values.first as int?) ?? 0;
    final tables = <String, Map<String, Object?>>{};
    for (final spec in syncTableSpecs) {
      final rows = _db.select(
        'SELECT COUNT(*) AS n FROM latest WHERE tbl = ? AND op <> ?',
        [spec.name, 'delete'],
      );
      final dead = _db.select(
        'SELECT COUNT(*) AS n FROM latest WHERE tbl = ? AND op = ?',
        [spec.name, 'delete'],
      );
      tables[spec.name] = {
        'live': (rows.first['n'] as int?) ?? 0,
        'deleted': (dead.first['n'] as int?) ?? 0,
      };
    }
    final devices = count('SELECT COUNT(*) AS n FROM devices');
    final events = count('SELECT COUNT(*) AS n FROM events');
    final maxSeq =
        (_db.select('SELECT COALESCE(MAX(seq), 0) AS s FROM events').first['s']
            as int?) ??
        0;
    final pending = activePairingCode(_db);
    return _json({
      'protocol': syncProtocolVersion,
      'admin_device_id': kAdminDeviceId,
      'tables': tables,
      'device_count': devices,
      'event_count': events,
      'max_seq': maxSeq,
      'pairing_code': pending?['code'],
      'pairing_expires_at': pending?['expires_at'],
      'admin_tables': const [
        'groups',
        'students',
        'score_items',
        'score_records',
        'course_schedule',
        'schedule_adjustment',
        'app_settings',
      ],
    });
  }

  // ---- 设备 ----

  Response _devices(Request request) {
    final rows = _db.select('''
      SELECT d.id, d.name, d.created_at, d.last_seen_at,
             (SELECT COUNT(*) FROM events e WHERE e.device_id = d.id) AS events,
             (SELECT MAX(e.created_at) FROM events e WHERE e.device_id = d.id)
               AS last_event_at
      FROM devices d ORDER BY d.created_at
    ''');
    return _json({
      'devices': [
        for (final r in rows)
          {
            'id': r['id'],
            'name': r['name'],
            'created_at': r['created_at'],
            'last_seen_at': r['last_seen_at'],
            'events': r['events'],
            'last_event_at': r['last_event_at'],
          },
      ],
    });
  }

  Response _revokeDevice(Request request, String id) {
    if (id == kAdminDeviceId) return _badRequest('不能撤销管理员设备');
    final rows = _db.select('SELECT name FROM devices WHERE id = ?', [id]);
    if (rows.isEmpty) return _notFound();
    _db.execute('DELETE FROM devices WHERE id = ?', [id]);
    writeAudit(
      _db,
      action: 'revoke_device',
      uid: id,
      before: {'name': rows.first['name']},
      sourceIp: clientIp(request),
    );
    // 设备侧的后果：下一次请求 401 → App 显示"需要重新配对"，本地数据不动。
    return _json({'ok': true});
  }

  // ---- 配对码 ----

  Response _pairing(Request request) {
    final active = activePairingCode(_db);
    return _json({
      'code': active?['code'],
      'expires_at': active?['expires_at'],
    });
  }

  Response _newPairing(Request request) {
    final code = issuePairingCode(_db);
    writeAudit(_db, action: 'issue_pairing_code', sourceIp: clientIp(request));
    final active = activePairingCode(_db);
    return _json({'code': code, 'expires_at': active?['expires_at']});
  }

  // ---- 表浏览 ----

  Response _table(Request request, String name) {
    final spec = syncTableSpec(name);
    if (spec == null) return _badRequest('unknown table: $name');
    final query = request.url.queryParameters;
    final offset = (int.tryParse(query['offset'] ?? '0') ?? 0).clamp(0, 1 << 30);
    final limit = (int.tryParse(query['limit'] ?? '50') ?? 50).clamp(1, 200);
    final q = (query['q'] ?? '').trim();
    final includeDeleted = query['deleted'] == '1';

    final where = <String>['tbl = ?'];
    final args = <Object?>[name];
    if (!includeDeleted) {
      where.add("op <> 'delete'");
    }
    if (q.isNotEmpty) {
      where.add('(uid LIKE ? OR payload LIKE ?)');
      args
        ..add('%$q%')
        ..add('%$q%');
    }
    final whereSql = where.join(' AND ');

    final total =
        (_db.select(
                  'SELECT COUNT(*) AS n FROM latest WHERE $whereSql',
                  args,
                ).first['n']
                as int?) ??
        0;
    final rows = _db.select(
      'SELECT uid, op, rev, rev_device, payload FROM latest WHERE $whereSql '
      'ORDER BY uid LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );

    return _json({
      'table': name,
      // 列名用 **payload 里的键**，不是表列名：外键在 payload 里已经被翻译成
      // `group_uid` / `score_item_uid` / `target_uid`，照表列名 `group_id`
      // 渲染会让那一列永远是空的（实测）。
      'columns': payloadColumns(spec),
      'editable': editableColumns(spec).toList(),
      'total': total,
      'offset': offset,
      'limit': limit,
      'rows': [
        for (final r in rows)
          _rowJson(
            uid: r['uid'] as String,
            op: r['op'] as String,
            rev: r['rev'] as int,
            revDevice: r['rev_device'] as String,
            payload: r['payload'] as String,
          ),
      ],
    });
  }

  Map<String, dynamic> _rowJson({
    required String uid,
    required String op,
    required int rev,
    required String revDevice,
    required String payload,
  }) {
    Map<String, dynamic>? data;
    try {
      data = (jsonDecode(payload) as Map).cast<String, dynamic>();
    } catch (_) {
      data = null;
    }
    return {
      'uid': uid,
      'op': op,
      'rev': rev,
      'rev_device': revDevice,
      'data': data,
    };
  }

  // ---- 编辑 ----

  /// 当前允许管理员编辑的列。
  ///
  /// 砍掉的三类：
  /// 1. **外键列**（`group_id` / `score_item_id` / `target_id`）：payload 里是
  ///    翻译后的 uid，改名要校验目标是否存在，改错会造出悬空引用；
  /// 2. **多态目标**（`target_type` + `target_id`）：改它等于把记录挪到别人名下，
  ///    语义上是"撤销重记"，不该是一个 PATCH 的副作用；
  /// 3. **语义主键**（`key` / `date`）：改它等于换一个逻辑对象，
  ///    而这两种列冲突策略是 preferLatest，改了会让对端的同键行被丢弃。
  ///
  /// 保留 `students.student_number`：它在客户端是 renumber 策略，
  /// 撞号时客户端会自己改号，服务端改它不会丢数据。
  static Set<String> editableColumns(SyncTableSpec spec) {
    final blocked = <String>{
      for (final fk in spec.foreignKeys) fk.column,
      for (final u in spec.localUnique)
        if (u.policy == UniqueConflictPolicy.preferLatest) u.column,
    };
    if (spec.name == 'score_records') {
      blocked
        ..add(scoreRecordTypeColumn)
        ..add(scoreRecordTargetColumn);
    }
    return spec.columns.where((c) => !blocked.contains(c)).toSet();
  }

  /// 一行在 payload 里实际存在的键，顺序按 [SyncTableSpec.columns]。
  ///
  /// 外键列（`group_id`）在推送时被翻译成 uid 键（`group_uid`），
  /// 多态目标（`target_id`）翻译成 `target_uid`。后台表格按这个集合出表头，
  /// 才能对着数据把值显示出来。
  static List<String> payloadColumns(SyncTableSpec spec) {
    final fkPayloadKeys = {
      for (final fk in spec.foreignKeys) fk.column: fk.payloadKey,
    };
    final out = <String>[];
    for (final column in spec.columns) {
      if (spec.name == 'score_records' && column == scoreRecordTargetColumn) {
        out.add(scoreRecordTargetUidKey);
        continue;
      }
      out.add(fkPayloadKeys[column] ?? column);
    }
    return out;
  }

  Future<Response> _edit(Request request, String name, String uid) async {
    final spec = syncTableSpec(name);
    if (spec == null) return _badRequest('unknown table: $name');

    final current = _db.select(
      'SELECT op, payload, rev FROM latest WHERE tbl = ? AND uid = ?',
      [name, uid],
    );
    if (current.isEmpty) return _notFound();
    // 已删除的行不支持编辑：复活一条墓碑在 App 里是"这条记录又出现了"，
    // 而回收站/孤儿记录的语义都建立在"墓碑 = 已删"之上。恢复应当由设备端做。
    if (current.first['op'] == 'delete') {
      return _badRequest('已删除的行不支持编辑');
    }

    final body = await _readJson(request);
    final patch = (body?['data'] as Map?)?.cast<String, dynamic>();
    if (patch == null || patch.isEmpty) return _badRequest('data required');

    final allowed = editableColumns(spec);
    Map<String, dynamic> old;
    try {
      old = (jsonDecode(current.first['payload'] as String) as Map)
          .cast<String, dynamic>();
    } catch (_) {
      return _badRequest('服务端存的这一行不是合法 JSON，拒绝编辑');
    }

    final updated = Map<String, dynamic>.from(old);
    for (final entry in patch.entries) {
      if (!allowed.contains(entry.key)) {
        return _badRequest('列不可编辑：${entry.key}');
      }
      final error = _typeError(old[entry.key], entry.value);
      if (error != null) return _badRequest('${entry.key}：$error');
      updated[entry.key] = entry.value;
    }

    final rev = nextEventRev(_db);
    final payload = jsonEncode(updated);
    _db.execute('BEGIN');
    try {
      appendEvent(
        _db,
        deviceId: kAdminDeviceId,
        table: name,
        uid: uid,
        op: 'upsert',
        rev: rev,
        revDevice: kAdminDeviceId,
        payload: payload,
      );
      writeAudit(
        _db,
        action: 'edit',
        tbl: name,
        uid: uid,
        before: {for (final k in patch.keys) k: old[k]},
        after: {for (final k in patch.keys) k: updated[k]},
        sourceIp: clientIp(request),
      );
      _db.execute('COMMIT');
    } catch (error) {
      _db.execute('ROLLBACK');
      return _json({'error': '$error'}, status: 500);
    }

    return _json({
      'ok': true,
      'rev': rev,
      'uid': uid,
      'data': updated,
    });
  }

  /// 类型校验：新值必须与旧值是同一类。
  ///
  /// 不校验的后果不是"报错"而是"客户端解析出错"：`score` 本来是 REAL，
  /// 若被改成字符串 "5"，客户端 `as num` 直接抛，那条事件会被计入
  /// "无法应用"，而且**每一轮拉取都会重试同一条**。
  String? _typeError(Object? before, Object? after) {
    if (after == null) return null; // 允许清空可空列
    if (before == null) return null; // 旧值就是 null，接受任何 JSON 标量
    if (before is num && after is num) return null;
    if (before is String && after is String) return null;
    if (before is bool && after is bool) return null;
    if (before.runtimeType == after.runtimeType) return null;
    return '类型不符，期望 ${before.runtimeType}';
  }

  // ---- 审计 ----

  Response _audit(Request request) {
    final rows = _db.select(
      'SELECT id, ts, actor, action, tbl, uid, before, after, source_ip '
      'FROM admin_audit ORDER BY id DESC LIMIT 200',
    );
    return _json({
      'entries': [
        for (final r in rows)
          {
            'id': r['id'],
            'ts': r['ts'],
            'actor': r['actor'],
            'action': r['action'],
            'table': r['tbl'],
            'uid': r['uid'],
            'before': _maybeJson(r['before'] as String?),
            'after': _maybeJson(r['after'] as String?),
            'source_ip': r['source_ip'],
          },
      ],
    });
  }

  Object? _maybeJson(String? text) {
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }

  // ---- 工具 ----

  String? _bearer(Request request) {
    final header = request.headers['authorization'] ?? '';
    if (!header.toLowerCase().startsWith('bearer ')) return null;
    return header.substring(7).trim();
  }

  Future<Map<String, dynamic>?> _readJson(Request request) async {
    try {
      final text = await request.readAsString();
      if (text.isEmpty) return null;
      return (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Response _json(Object body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  );

  Response _badRequest(String message) => _json({'error': message}, status: 400);

  Response _notFound() => _json({'error': 'not found'}, status: 404);
}
