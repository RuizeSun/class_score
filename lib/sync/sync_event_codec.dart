import 'dart:convert';

import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 事件编解码：本地行 ↔ 线上事件。
///
/// 三件事在这里收口：
/// 1. **外键翻译**：本地自增 id → uid（推送时），uid → 本地 id（拉取时）；
/// 2. **多态外键**：`score_records.target_id` 指向学生或小组，由 `target_type` 决定；
/// 3. **未知 uid 的占位**：远端事件先到、父行后到时，先建一个占位行，
///    等父行到达再补内容（否则外键悬空，统计会算错）。
///
/// 局限：如果父行始终不来（对端删干净了），会留下一个空名字的占位行。
/// 这类悬挂由 `SyncEngine` 在每轮同步后统计并暴露在设置页，不做自动删除
/// （自动删除可能把真实数据一起删掉）。
class SyncEventCodec {
  SyncEventCodec(this._db);

  /// 冲突协调后「这一条事件应当写到哪一行」（null 表示按 uid 常规处理）。
  ///
  /// 只有 [UniqueConflictPolicy.preferLatest] 会用到：远端版本更新时，它要
  /// 就地覆盖本地那一行而不是新建。用实例字段而不是返回值，是为了不给
  /// _reconcileUniqueColumns 再加一个返回维度；每次 applyRemote 开头重置，
  /// 且 codec 不是共享单例，因此不会在事件之间串味。
  int? _localOverride;

  final Database _db;

  /// 当前事务；非事务调用时为 null。[applyRemote] 全程跑在事务里。
  Transaction? _txn;

  DatabaseExecutor get _exec => _txn ?? _db;

  // ---- 推送方向 ----

  /// 读一批 outbox 行，翻译成线上事件。
  ///
  /// **无法解码的行在这里直接丢弃**，而不是原样留着：`_push` 只删除"已成功
  /// 推送的 seq"，一行解不出事件（未知表名 / payload 不是合法 JSON）就永远
  /// 停留在队首被每轮重读，整条推送链从此卡死——而且它不计入任何指标，
  /// 界面上表现为"同步一直在跑、待推送永远减不下去"。
  ///
  /// 这类行没有任何修复途径（内容本身就坏了），丢掉是唯一正确的处置。
  /// 丢弃条数记在 [droppedOutboxRows] 里，供设置页暴露。
  Future<List<SyncEvent>> readOutbox({int limit = 200}) async {
    final rows = await _exec.query(
      'sync_outbox',
      orderBy: 'seq',
      limit: limit,
    );
    final events = <SyncEvent>[];
    final poison = <int>[];
    for (final row in rows) {
      final event = await _decodeOutboxRow(row);
      if (event != null) {
        events.add(event);
      } else {
        poison.add(row['seq'] as int);
      }
    }
    if (poison.isNotEmpty) {
      droppedOutboxRows += poison.length;
      await _exec.delete(
        'sync_outbox',
        where: 'seq IN (${List.filled(poison.length, '?').join(',')})',
        whereArgs: poison,
      );
    }
    return events;
  }

  /// 累计被丢弃的不可解码事件数。
  ///
  /// 用静态字段而不是实例字段：[SyncEventCodec] 每轮同步都会新建一个，
  /// 实例上的计数会立刻归零，等于没有。
  static int droppedOutboxRows = 0;

  Future<SyncEvent?> _decodeOutboxRow(Map<String, dynamic> row) async {
    final table = row['tbl'] as String;
    final spec = syncTableSpec(table);
    if (spec == null) return null;

    Map<String, dynamic> payload;
    try {
      payload = (jsonDecode(row['payload'] as String) as Map)
          .cast<String, dynamic>();
    } catch (_) {
      return null;
    }
    final data = await _translateForeignKeysOut(spec, payload);
    return SyncEvent(
      table: table,
      uid: row['uid'] as String,
      op: SyncOp.fromWire(row['op'] as String),
      rev: row['rev'] as int,
      revDevice: row['rev_device'] as String,
      data: data,
      seq: row['seq'] as int,
    );
  }

  /// 把本地**所有活行**转成事件，供首次配对时的初始上传使用。
  ///
  /// 这是"启用同步之前就有的数据"唯一的出路：迁移时刻意没有给历史行
  /// 记 outbox（否则升级当天会凭空多出几千条待推送事件），因此这些行
  /// 永远不会自己进事件流——必须显式扫一遍。
  ///
  /// [startRev] 是这条事件流的起始 rev。调用方要保证它**大于服务端已知的
  /// 最大 rev**，否则上传上去的版本会输给服务端已有的旧数据。
  /// 每条事件递增 1，避免同一批里多个版本号相同（那会让 LWW 退化成比
  /// rev_device 字符串，结果不可预期）。
  Future<List<SyncEvent>> snapshotLocalRows({
    required int startRev,
    required String deviceId,
  }) async {
    final events = <SyncEvent>[];
    var rev = startRev;
    for (final spec in syncTableSpecs) {
      // `app_settings` 必须**按白名单**取行。
      //
      // 触发器里也有同样的白名单，但这里是绕开触发器直接扫表的另一条路：
      // v11 迁移的 _backfill 给这张表的**所有**历史行都补了 uid，所以老用户
      // 升级后第一次配对，整张设置表（含 pin_hash、主题色、天气城市）都会被
      // 当成"历史数据"推上服务端。实测确实泄漏了 pin_hash。
      //
      // 白名单只写在一处（协议包里的 syncedSettingKeys），触发器与这里共用。
      final where = StringBuffer('deleted_at IS NULL');
      final whereArgs = <Object?>[];
      if (spec.name == 'app_settings') {
        final keys = syncedSettingKeys.toList();
        where.write(' AND key IN (${List.filled(keys.length, '?').join(',')})');
        whereArgs.addAll(keys);
      }
      final rows = await _exec.query(
        spec.name,
        where: where.toString(),
        whereArgs: whereArgs,
        orderBy: 'id',
      );
      for (final row in rows) {
        final uid = row['uid'] as String?;
        if (uid == null || uid.isEmpty) continue;
        // 只取业务列：同步元数据（uid/rev/deleted_at）不该出现在 payload 里，
        // 否则会和 SyncEvent 自己的字段打架。
        final payload = <String, dynamic>{
          for (final column in spec.columns) column: row[column],
        };
        final data = await _translateForeignKeysOut(spec, payload);
        rev++;
        events.add(
          SyncEvent(
            table: spec.name,
            uid: uid,
            op: SyncOp.upsert,
            rev: rev,
            revDevice: deviceId,
            data: data,
          ),
        );
      }
    }
    return events;
  }

  /// 本地活行总数（初始上传前用来判断"本地有没有数据"）。
  ///
  /// **不含 `app_settings`**：新建的库一定有几行默认设置（`current_period`
  /// 等），把它们算进来会让"本地有数据"永远为真，于是每次首次配对都会
  /// 弹出"两端都有数据，请选择"——而实际上本地只是默认配置。
  Future<int> countLocalRows() async {
    var total = 0;
    for (final spec in syncTableSpecs) {
      if (spec.name == 'app_settings') continue;
      final rows = await _exec.rawQuery(
        'SELECT COUNT(*) AS n FROM ${spec.name} WHERE deleted_at IS NULL',
      );
      total += (rows.first['n'] as int?) ?? 0;
    }
    return total;
  }

  /// 所有本地活行的 (表, uid)，保留远端时用来找出"服务端没有的行"。
  ///
  /// 与 [countLocalRows] 一致地跳过 `app_settings`：默认设置行本来就该由
  /// 「保留远端」的服务端值覆盖，把它们当"本地独有"打墓碑会连当前周期
  /// 一起抹掉。
  Future<List<({String table, String uid})>> localLiveUids() async {
    final out = <({String table, String uid})>[];
    for (final spec in syncTableSpecs) {
      if (spec.name == 'app_settings') continue;
      final rows = await _exec.query(
        spec.name,
        columns: ['uid'],
        where: 'deleted_at IS NULL',
      );
      for (final row in rows) {
        final uid = row['uid'] as String?;
        if (uid == null || uid.isEmpty) continue;
        out.add((table: spec.name, uid: uid));
      }
    }
    return out;
  }

  /// 给一行打墓碑，**且不记 outbox**（只影响本地）。
  ///
  /// 用在"保留远端"：用户明确表示本地数据作废，但这些行不该反过来被推上去
  /// 污染对端，所以用 applying 开关抑制记账。
  Future<void> tombstoneLocally(String table, String uid) async {
    await _exec.execute(
      "UPDATE sync_state SET value = '1' WHERE key = 'applying'",
    );
    try {
      await _exec.update(
        table,
        {
          'deleted_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'uid = ? AND deleted_at IS NULL',
        whereArgs: [uid],
      );
    } finally {
      await _exec.execute(
        "UPDATE sync_state SET value = '0' WHERE key = 'applying'",
      );
    }
  }

  /// 本地 id → uid。翻译不出来（父行已被物理删除）时写 null，
  /// 让对端知道"这个引用悬空"，而不是把 -1 当成一个真实 id 传过去。
  Future<Map<String, dynamic>> _translateForeignKeysOut(
    SyncTableSpec spec,
    Map<String, dynamic> payload,
  ) async {
    final out = Map<String, dynamic>.from(payload);
    for (final fk in spec.foreignKeys) {
      final localId = out.remove(fk.column);
      out[fk.payloadKey] = localId == null
          ? null
          : await _uidOf(fk.targetTable, localId as int);
    }
    if (spec.name == 'score_records') {
      final type = out[scoreRecordTypeColumn] as String?;
      final localId = out[scoreRecordTargetColumn] as int?;
      final targetTable = scoreTargetTable(type);
      out[scoreRecordTargetUidKey] = localId == null || targetTable == null
          ? null
          : await _uidOf(targetTable, localId);
      // 本地 id 不跨设备，去掉以免对端误用
      out.remove(scoreRecordTargetColumn);
    }
    return out;
  }

  Future<String?> _uidOf(String table, int localId) async {
    final rows = await _exec.query(
      table,
      columns: ['uid'],
      where: 'id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['uid'] as String?;
  }

  // ---- 拉取方向 ----

  /// 把一条远端事件应用到本地。返回 true 表示本地确实发生了变化。
  ///
  /// **不写 outbox**：整个应用过程跑在 `applying = '1'` 里，触发器看到这个
  /// 标记就不记账，从而彻底切断 A→服务端→A 的回环。
  ///
  /// **整条事件跑在一个事务里**，这是必需的，不是优化：
  /// 1. 应用一条事件要跨很多次 await（查 uid、翻外键、协调唯一列、再写行），
  ///    期间的写入会被 `applying` 标记吞掉（触发器 WHEN 不成立）。放进事务
  ///    只是让这个窗口不至于更长，真正的隔离由 SQLite 的事务锁提供；
  /// 2. 任何一步失败都必须整条回滚。之前 `_applyInner` 先抬 lamport 再写行，
  ///    写行失败就会留下"lamport 已抬高、数据没进来"的半写状态，而游标照样
  ///    前进 → 这条事件永远不会重放。
  Future<bool> applyRemote(SyncEvent event) async {
    final spec = syncTableSpec(event.table);
    if (spec == null) return false;

    return _db.transaction((txn) async {
      _txn = txn;
      try {
        await txn.execute(
          "UPDATE sync_state SET value = '1' WHERE key = 'applying'",
        );
        return await _applyInner(spec, event);
      } finally {
        // 事务回滚时这条也一起回滚，所以异常路径不需要额外复位。
        await txn.execute(
          "UPDATE sync_state SET value = '0' WHERE key = 'applying'",
        );
        _txn = null;
      }
    });
  }

  Future<bool> _applyInner(SyncTableSpec spec, SyncEvent event) async {
    final local = await _findByUid(spec.name, event.uid);
    final localRev = local?['rev'] as int?;
    if (!remoteWins(
      remote: event,
      localRev: localRev,
      localDevice: local?['rev_device'] as String?,
    )) {
      return false;
    }

    // lamport 必须至少抬到远端 rev：否则本机下一次写入会拿到更小的号，
    // 永远赢不过这条远端版本（LWW 退化成"远端永久压制本地"）。
    //
    // 但**不能越过安全上限**：超过 int64 后 SQLite 的 `CAST(... AS INTEGER)+1`
    // 会退化成 REAL，lamport 从此以浮点字符串形态存在
    // （实测变成 '9.22337203685478e+18'），本地 Lamport 时钟损坏、
    // 触发器取号全部失效。远端事件来自服务端（它已拒收超限 rev），
    // 但拉取端仍要独立兜底——这台设备可能连上过一台被污染的服务端。
    // 钳制到 maxSafeRev：比库里的任何正常行都大（能赢 LWW），
    // 却不再给 +1 留出溢出空间。
    if (event.rev > maxSafeRev) {
      await _exec.rawUpdate(
        "UPDATE sync_state SET value = ? WHERE key = 'lamport'",
        ['$maxSafeRev'],
      );
    } else {
      await _exec.rawUpdate(
        "UPDATE sync_state SET value = MAX(CAST(value AS INTEGER), ?) "
        "WHERE key = 'lamport'",
        [event.rev],
      );
    }

    final data = await _translateForeignKeysIn(spec, event);
    if (event.op == SyncOp.delete) {
      if (local == null) {
        // 还没见过这一行就被删除：仍然落一条墓碑，避免"先删后到"的顺序问题。
        await _insertPlaceholder(spec, event, tombstone: true);
      } else {
        await _exec.update(
          spec.name,
          {
            'deleted_at': DateTime.now().toIso8601String(),
            'rev': event.rev,
            'rev_device': event.revDevice,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [local['id']],
        );
      }
      await _rememberUid(spec.name, event.uid, local?['id'] as int? ?? -1);
      return true;
    }

    // 表内唯一列（学号、调休日期）可能跨设备撞车，写库前先协调。
    final reconciled = await _reconcileUniqueColumns(spec, data, event);
    if (reconciled == null) {
      // 语义上不允许并存（某天的调休只有一条），本地版本更新：整条丢弃。
      return false;
    }

    // preferLatest 撞车时指定了「就地覆盖本地那一行」（uid 保持本地的不变），
    // 这样同一个 key / 同一天永远只有一条活行。
    final targetId = _localOverride ?? local?['id'] as int?;

    if (targetId == null) {
      final id = await _exec.insert(spec.name, {
        ...reconciled,
        'uid': event.uid,
        'rev': event.rev,
        'rev_device': event.revDevice,
        'updated_at': DateTime.now().toIso8601String(),
      });
      await _rememberUid(spec.name, event.uid, id);
      return true;
    }

    await _exec.update(
      spec.name,
      {
        ...reconciled,
        // 就地覆盖时保留本地 uid：远端那个 uid 只是同一逻辑键的另一个副本。
        if (_localOverride == null) 'uid': event.uid,
        'rev': event.rev,
        'rev_device': event.revDevice,
        'updated_at': DateTime.now().toIso8601String(),
        // 远端复活（uid 相同但 op=upsert）：清掉本地墓碑，否则查不出来。
        'deleted_at': null,
      },
      where: 'id = ?',
      whereArgs: [targetId],
    );
    await _rememberUid(spec.name, event.uid, targetId);
    return true;
  }

  /// uid → 本地 id。父行还没到时建一个**局部占位行**：名字留空、带下划线
  /// 前缀的 uid，等父行事件到达时 by-uid 命中并覆盖内容。
  Future<Map<String, dynamic>> _translateForeignKeysIn(
    SyncTableSpec spec,
    SyncEvent event,
  ) async {
    final data = Map<String, dynamic>.from(event.data ?? const {});
    for (final fk in spec.foreignKeys) {
      final uid = data.remove(fk.payloadKey) as String?;
      data[fk.column] = await _resolveLocalId(spec.name, fk.column, fk.targetTable, uid);
    }
    if (spec.name == 'score_records') {
      final targetUid = data.remove(scoreRecordTargetUidKey) as String?;
      final type = data[scoreRecordTypeColumn] as String?;
      final targetTable = scoreTargetTable(type);
      data[scoreRecordTargetColumn] = await _resolveLocalId(
        spec.name,
        scoreRecordTargetColumn,
        targetTable,
        targetUid,
      );
    }
    return data;
  }

  /// 解析一个外键；解析不出来时按列的可空性给一个安全值。
  ///
  /// 为什么不能直接写 null：`score_records.target_id` 与 `students.group_id`
  /// 都是 NOT NULL。远端发来一条 target_type 不认识（或父行已被彻底删除）的
  /// 事件时，写 null 会让 INSERT 抛约束错误——而 applyRemote 一旦抛异常，
  /// 拉取循环就中断、游标不前进，**下一轮还会拿到同一条事件**，同步从此死循环。
  ///
  /// 因此不可空的外键用 0 兜底（自增 id 从 1 开始，0 天然不指向任何行，
  /// 界面上表现为"未知对象"，统计时也不会误算）。
  Future<int?> _resolveLocalId(
    String table,
    String column,
    String? targetTable,
    String? uid,
  ) async {
    if (targetTable != null && uid != null) {
      return _localIdFor(targetTable, uid);
    }
    return await _isNotNull(table, column) ? 0 : null;
  }

  /// 查一张表里"没有默认值且 NOT NULL"的列。
  ///
  /// 不做缓存：[SyncEventCodec] 是 const 构造的轻量对象，每次同步都会新建；
  /// 而 PRAGMA 只在解析失败（罕见）时才会走到，多查一次不构成开销。
  Future<bool> _isNotNull(String table, String column) async {
    final info = await _exec.rawQuery('PRAGMA table_info($table)');
    for (final row in info) {
      if (row['name'] != column) continue;
      final notNull = (row['notnull'] as int? ?? 0) == 1;
      return notNull && row['dflt_value'] == null;
    }
    return false;
  }

  Future<Map<String, dynamic>?> _findByUid(String table, String uid) async {
    final rows = await _exec.query(
      table,
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> _localIdFor(String table, String uid) async {
    final mapped = await _exec.query(
      'sync_uid_map',
      where: 'tbl = ? AND uid = ?',
      whereArgs: [table, uid],
      limit: 1,
    );
    if (mapped.isNotEmpty) return mapped.first['local_id'] as int;

    final row = await _findByUid(table, uid);
    if (row != null) {
      final id = row['id'] as int;
      await _rememberUid(table, uid, id);
      return id;
    }
    final spec = syncTableSpec(table);
    if (spec == null) return -1;
    final id = await _insertPlaceholder(spec, null, uid: uid);
    await _rememberUid(table, uid, id);
    return id;
  }

  /// 建一行占位。
  ///
  /// [tombstone] 为 true 时占位行直接是"已删除"状态（用于"先删后到"的事件）；
  /// 为 false 时占位行可见——它是"父行还没到"的临时身份，父行到达后会被覆盖。
  /// 占位行必须满足各表的 NOT NULL 约束，所以按表给一组最小可用的默认值。
  Future<int> _insertPlaceholder(
    SyncTableSpec spec,
    SyncEvent? event, {
    String? uid,
    bool tombstone = false,
  }) async {
    final now = DateTime.now().toIso8601String();
    final base = <String, dynamic>{
      'uid': uid ?? event?.uid ?? '',
      'rev': event?.rev ?? 0,
      'rev_device': event?.revDevice ?? '',
      'updated_at': now,
      'deleted_at': tombstone ? now : null,
    };
    switch (spec.name) {
      case 'groups':
        base['name'] = '';
      case 'students':
        base['name'] = '';
        // 占位行的学号必须**各不相同**：唯一索引（部分索引）允许多个空串吗？
        // 不允许——第二个占位行就会撞 UNIQUE。用 uid 派生一个不会与真实
        // 学号冲突的占位值（真实学号是纯数字或空串）。
        base['student_number'] = '~pending~${base['uid']}';
        // `students.group_id` 是 **NOT NULL**，这里曾经写 null ——
        // 配合下面的 `ConflictAlgorithm.ignore`，INSERT 被静默跳过并返回 0，
        // 占位行根本没建出来。后果是评分记录指向一个不存在的学生，
        // 被 `_resolveLocalId` 兜成 `target_id = 0`，即使学生之后到了也不会
        // 回填（`_rememberUid` 对 localId <= 0 直接 return），
        // 这条分数永久不进任何统计。用 0 兜底（自增 id 从 1 开始，指向空）。
        base['group_id'] = 0;
      case 'score_items':
        base['name'] = '';
        base['default_score'] = 0;
        base['description'] = '';
      case 'score_records':
        base['target_type'] = 'student';
        base['score'] = 0;
        base['create_time'] = DateTime.now().toIso8601String();
      case 'course_schedule':
        base['weekday'] = 1;
        base['course_name'] = '';
        base['start_time'] = '00:00';
        base['end_time'] = '00:00';
      case 'schedule_adjustment':
        base['date'] = '1970-01-01';
        base['weekday'] = 0;
        base['created_at'] = DateTime.now().toIso8601String();
    }
    // 返回真正的本地 id。
    //
    // 这里曾经用 `ConflictAlgorithm.ignore` 且直接返回 `insert()` 的结果：
    // 一旦 INSERT 因约束被跳过（比如某个 NOT NULL 列没给值），返回的是 **0**，
    // 而 0 会被当成合法 id 写进外键列，`_rememberUid` 又会因 `localId <= 0`
    // 直接跳过记录 —— 于是一个"根本没建出来的占位行"变成了永久的悬空引用。
    // 现在强制回读一次真实行：建不出来就直接抛，让上层按"这条事件失败"处理
    // （重试到毒事件为止），而不是静默写进一个错误的外键。
    await _exec.insert(
      spec.name,
      base,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final created = await _findByUid(spec.name, base['uid'] as String);
    final id = created?['id'] as int?;
    if (id == null || id <= 0) {
      throw StateError('无法为 ${spec.name} 建立占位行（uid=${base['uid']}）');
    }
    return id;
  }

  // ---- 表内唯一列的跨设备协调 ----

  /// 处理"本表内部唯一、但跨设备不唯一"的列。
  ///
  /// 唯一索引只在一台设备内成立。两台设备各自离线时，完全可能给不同对象分配
  /// 同一个值（最典型：两边都从"下一个空学号"开始算，各得一个 01）。
  /// 不处理的话，远端那条 INSERT 会撞 UNIQUE —— 在拉取循环里被 catch 掉、
  /// 只进一个计数，表现为"有个学生就是同步不过来"。
  ///
  /// 返回 null 表示这一行应当**整条丢弃**（语义上不允许并存的情形）；
  /// 否则返回（可能已改写过的）数据。
  Future<Map<String, dynamic>?> _reconcileUniqueColumns(
    SyncTableSpec spec,
    Map<String, dynamic> data,
    SyncEvent event,
  ) async {
    if (spec.localUnique.isEmpty) return data;
    var out = data;
    _localOverride = null;
    for (final unique in spec.localUnique) {
      final key = unique.column;
      final incoming = out[key];
      if (incoming == null) continue;
      // 只有**另起一行**才算冲突：uid 相同的是同一行，那是普通的更新，
      // 交给 LWW 处理就行（否则自己会和自己撞）。
      final clash = await _exec.query(
        spec.name,
        columns: ['id', 'uid', 'rev', 'rev_device'],
        where: '$key = ? AND deleted_at IS NULL AND uid <> ?',
        whereArgs: [incoming, event.uid],
        limit: 1,
      );
      if (clash.isEmpty) continue;
      switch (unique.policy) {
        case UniqueConflictPolicy.preferLatest:
          // 语义上不允许并存（某天的调休、某个设置键）。按 rev 裁决：
          // 远端更旧就整条丢弃，更新就让它**就地覆盖**本地那一行。
          //
          // 为什么是"就地覆盖"而不是"把本地那行打成墓碑再插入"：
          // 后者会让同一个 key 短暂出现两条活行（墓碑化 + 新插入），
          // 而唯一索引只排除墓碑，于是插入时又撞上"另一条活行"。
          // 就地覆盖保持 uid 不变，也天然满足"一行一个 key"。
          final current = clash.first;
          final remoteIsNewer = compareRevision(
            aRev: event.rev,
            aDevice: event.revDevice,
            bRev: current['rev'] as int,
            bDevice: current['rev_device'] as String,
          ) > 0;
          if (!remoteIsNewer) return null;
          // 记录"这一条要写到哪一行"：用 [localOverride] 把目标换成本地那行。
          _localOverride = current['id'] as int;
        case UniqueConflictPolicy.renumber:
          // 人的身份不能因为编号撞了就被丢掉：给晚到的这一个换一个空号。
          out = Map<String, dynamic>.from(out);
          out[key] = await _nextFreeValue(
            spec.name,
            key,
            incoming as Object,
          );
      }
    }
    return out;
  }

  /// 找一个尚未占用的值：数字型在原值上递增，其它类型追加后缀。
  Future<String> _nextFreeValue(String table, String column, Object current) async {
    final text = '$current';
    final numeric = int.tryParse(text);
    if (numeric == null) {
      var suffix = 2;
      while (true) {
        final candidate = '$text-$suffix';
        final taken = await _exec.query(
          table,
          columns: ['id'],
          where: '$column = ?',
          whereArgs: [candidate],
          limit: 1,
        );
        if (taken.isEmpty) return candidate;
        suffix++;
      }
    }
    var next = numeric + 1;
    while (true) {
      final candidate = next.toString();
      final taken = await _exec.query(
        table,
        columns: ['id'],
        where: '$column = ?',
        whereArgs: [candidate],
        limit: 1,
      );
      if (taken.isEmpty) return candidate;
      next++;
    }
  }

  Future<void> _rememberUid(String table, String uid, int localId) async {
    if (localId <= 0) return;
    await _exec.insert('sync_uid_map', {
      'tbl': table,
      'uid': uid,
      'local_id': localId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}