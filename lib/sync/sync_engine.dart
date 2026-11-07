import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';
import 'sync_client.dart';
import 'sync_event_codec.dart';

/// 同步状态：UI 只读这一个枚举。
enum SyncStatus {
  /// 未配置服务器，同步功能关闭（默认）。
  disabled,

  /// 已配置但当前连不上。App 全功能照常，只把状态点画成灰色。
  offline,

  /// 空闲（上一次同步成功且没有待推送事件）。
  idle,

  /// 正在推送/拉取。
  syncing,

  /// 需要重新配对（token 失效）。
  authRequired,

  /// 非网络类错误（服务端 500、协议版本不符等）。
  error,
}

// ---- 初始上传与首次会合 ----

/// 首次配对后的"会合"状态。
enum InitialSyncState {
  /// 还没走完（服务端空 → 正在上传；或两端都有数据 → 等用户选）。
  pending,

  /// 本地与远端已经一致，之后走普通增量同步。
  done,
}

/// 两端都有数据时，用户要三选一。
enum MergeChoice {
  /// 逐行按 rev 裁决（默认，也是唯一"不丢数据"的选项）。
  merge,

  /// 本地赢：本地活行整体覆盖服务端同 uid 的行。
  keepLocal,

  /// 远端赢：服务端所有行覆盖本地；服务端没有的本地行**打墓碑**。
  keepRemote,
}

/// 两端都有数据时给用户看的对比。
///
/// 只统计"行数"，不列具体差异：老师要判断的是"哪一边是我要的"，
/// 而不是逐行比对；后者应该由服务端管理后台来做。
class InitialMergePreview {
  const InitialMergePreview({
    required this.localRows,
    required this.remoteRows,
    required this.remoteMaxRev,
  });

  /// 本地活行数。
  final int localRows;

  /// 服务端活行数。
  final int remoteRows;

  /// 服务端已知的最大 rev。
  final int remoteMaxRev;
}

/// 同步内核：把 outbox 推上去、把远端事件拉下来。
///
/// 设计红线（与 docs/sync-server-feasibility.md 一致）：
/// 1. **写路径绝不 await 网络**——所有同步都由本类的定时器 / 通知触发；
/// 2. 失败只改状态，不弹框、不阻塞、不丢事件（outbox 是同一事务写的）；
/// 3. 应用远端事件时不记账（`applying` 标记 + 触发器守卫），杜绝打环。
class SyncEngine extends ChangeNotifier {
  SyncEngine._();

  static final SyncEngine instance = SyncEngine._();

  /// 写操作后延迟这么久再同步，避免连续评分时刷爆请求。
  static const Duration debounce = Duration(seconds: 5);

  /// 心跳间隔。
  static const Duration heartbeat = Duration(minutes: 1);

  /// 单次推送的事件上限。
  static const int pushBatch = 200;

  /// 单次拉取的事件上限。
  static const int pullBatch = 500;

  /// 首次配对后的会合状态。
  ///
  /// 同步功能上线之前产生的数据不会自己进 outbox（迁移时刻意不记，
  /// 否则升级当天会凭空多出几千条待推送事件），所以首次配对必须主动
  /// 走一趟"会合"：服务端空就把本地整体上传；两端都有数据就让用户选。
  InitialSyncState _initialState = InitialSyncState.done;
  InitialSyncState get initialState => _initialState;

  /// 两端都有数据、等用户选择时的统计（用于界面展示）。
  InitialMergePreview? _mergePreview;
  InitialMergePreview? get mergePreview => _mergePreview;

  bool get needsMergeDecision =>
      _initialState == InitialSyncState.pending && _mergePreview != null;

  /// 会合是否正在跑（上传中 / 拉快照中）。UI 用它禁用按钮。
  bool _initialBusy = false;
  bool get initialBusy => _initialBusy;

  SyncStatus _status = SyncStatus.disabled;
  SyncStatus get status => _status;

  DateTime? _lastSuccessAt;
  DateTime? get lastSuccessAt => _lastSuccessAt;

  int _pendingCount = 0;
  int get pendingCount => _pendingCount;

  String? _lastError;
  String? get lastError => _lastError;

  SyncClient? _client;
  Timer? _debounceTimer;
  Timer? _heartbeatTimer;
  bool _running = false;

  /// 连续失败次数，用于指数退避。
  int _failures = 0;

  /// 上一轮拉取里无法应用的事件条数（0 表示全部成功）。
  ///
  /// 单条事件失败不会中断同步（见 [_pull]），因此需要一个可见的计数，
  /// 否则"同步一直在跑、但有些数据就是没进来"会完全无声。
  int _rejectedEvents = 0;
  int get rejectedEvents => _rejectedEvents;

  /// 服务端逐条拒收的累计条数。
  int _droppedOnPush = 0;

  /// 累计被丢弃的事件数（不可编码的 outbox 行 + 服务端逐条拒收的）。
  ///
  /// 这些事件永远到不了对端，必须可见，否则就是"同步正常但数据少了"。
  int get droppedEvents =>
      SyncEventCodec.droppedOutboxRows + _droppedOnPush;

  /// 悬挂的占位行数量（父行迟迟不到，留下空名字的行）。
  ///
  /// 不自动清理：自动删可能把真实数据一起删掉。这里只把它数出来，
  /// 让设置页能显示出"库里有 N 行是占位、不是真实数据"，
  /// 否则它会以"一个没有名字的学生"的形式永远潜伏在名单里。
  int _orphanPlaceholders = 0;
  int get orphanPlaceholders => _orphanPlaceholders;

  /// 退避到期前不再尝试。
  DateTime _nextAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isConfigured => _client != null;

  /// 按库里的配置重建客户端并开始心跳。启动时调用一次。
  Future<void> configure() async {
    final db = await DatabaseHelper.instance.database;
    // 上次进程可能死在"应用远端事件"中途，`applying` 停在 '1'。
    // 这个标记是**持久化**在 sync_state 里的，没有任何代码会在启动时复位它，
    // 于是此后所有写入的触发器 WHEN 都不成立 —— 编辑照常生效、界面照常刷新、
    // outbox 一条都不涨，同步从此静默停摆（实测：导入后连改名都不再记事件）。
    // 启动时进程里一定没有同步在跑，直接复位是安全的。
    await db.execute("UPDATE sync_state SET value = '0' WHERE key = 'applying'");

    // lamport 自愈：旧版本在 lamport 逼近 int64 时，触发器的
    // `CAST(value AS INTEGER) + 1` 会退化成 REAL 并存成浮点字符串
    // （'9.22337203685478e+18'）。这会让本地 Lamport 时钟永久损坏——
    // 之后每一次取号都得到同一个浮点数。启动时把非整数的 lamport
    // 归位到 maxSafeRev（库里任何正常行都比它小，LWW 仍然能赢）。
    final lamportRow = await db.rawQuery(
      "SELECT value FROM sync_state WHERE key = 'lamport'",
    );
    final lamportRaw = lamportRow.first['value'] as String?;
    if (lamportRaw == null || int.tryParse(lamportRaw) == null) {
      await db.execute(
        "UPDATE sync_state SET value = ? WHERE key = 'lamport'",
        ['$maxSafeRev'],
      );
    }

    final rows = await db.query('sync_state');
    final state = {for (final r in rows) r['key'] as String: r['value'] as String};

    final baseUrl = (state['server_url'] ?? '').trim();
    final token = (state['token'] ?? '').trim();
    final deviceId = (state['device_id'] ?? '').trim();

    _client?.close();
    _client = null;
    _serverUrl = baseUrl;

    if (baseUrl.isEmpty || token.isEmpty) {
      _setStatus(SyncStatus.disabled);
      return;
    }
    // 设备 id 在首次配对时由服务端确认，本地没写就补一个。
    final effectiveDeviceId = deviceId.isEmpty
        ? await _ensureDeviceId(db)
        : deviceId;

    await db.rawUpdate(
      "UPDATE sync_state SET value = ? WHERE key = 'device_id'",
      [effectiveDeviceId],
    );
    final pemPath = (state['ca_pem_path'] ?? '').trim();
    List<int>? pem;
    if (pemPath.isNotEmpty) {
      try {
        final file = File(pemPath);
        if (await file.exists()) pem = await file.readAsBytes();
      } catch (error) {
        debugPrint('读取同步服务端证书失败：$error');
      }
    }
    _client = SyncClient(
      baseUrl: baseUrl,
      token: token,
      trustedCertificatePem: pem,
    );
    // 首次配对后还没走完会合：状态保持 pending，由 syncNow 触发。
    _initialState = (state['initial_sync_done'] ?? '') == '1'
        ? InitialSyncState.done
        : InitialSyncState.pending;
    _setStatus(SyncStatus.idle);
    _startHeartbeat();
    // 启动即跑一轮：把上次退出时积压的事件补上去。
    unawaited(syncNow());
  }

  /// 配对：输入服务端地址 + 一次性配对码。
  Future<String?> pair({
    required String serverUrl,
    required String code,
    String? caPemPath,
  }) async {
    final db = await DatabaseHelper.instance.database;
    final deviceId = await _ensureDeviceId(db);
    List<int>? pem;
    final trimmedPath = (caPemPath ?? '').trim();
    if (trimmedPath.isNotEmpty) {
      try {
        final file = File(trimmedPath);
        if (!await file.exists()) return '证书文件不存在：$trimmedPath';
        pem = await file.readAsBytes();
      } catch (error) {
        return '无法读取证书文件：$error';
      }
    }
    final client = SyncClient(
      baseUrl: serverUrl,
      token: '',
      trustedCertificatePem: pem,
    );
    final result = await client.pair(
      code: code,
      deviceId: deviceId,
      deviceName: Platform.localHostname,
    );
    client.close();
    if (result == null) {
      return '配对失败：地址或配对码不正确';
    }
    await _setState(db, 'server_url', serverUrl);
    if (caPemPath != null) {
      await _setState(db, 'ca_pem_path', caPemPath.trim());
    }
    _serverUrl = serverUrl;
    await _setState(db, 'token', result.token);
    await _setState(db, 'device_id', result.deviceId);
    // 重新配对 = 可能是换了一台服务端，会合必须重跑，
    // 否则新服务端上永远不会有这台设备的历史数据。
    await _setState(db, 'initial_sync_done', '0');
    await _setState(db, 'server_seq', '0');
    _initialState = InitialSyncState.pending;
    _mergePreview = null;
    await configure();
    return null;
  }

  /// 解除绑定：保留本地数据，只清掉服务器配置。
  Future<void> unpair() async {
    final db = await DatabaseHelper.instance.database;
    await _setState(db, 'server_url', '');
    await _setState(db, 'token', '');
    _heartbeatTimer?.cancel();
    _debounceTimer?.cancel();
    _client?.close();
    _client = null;
    _serverUrl = '';
    _setStatus(SyncStatus.disabled);
  }

  /// 当前配置的服务端地址（未配置时返回空串）。
  ///
  /// 刻意用内存缓存而不是查库：设置页在 initState 里就要回显地址，
  /// 而 UI 在首帧去开数据库既慢又会在测试里留下真实文件。
  /// 缓存由 [configure] / [pair] 写入，两条路径都发生在写库之后。
  String _serverUrl = '';
  String get serverUrl => _serverUrl;

  /// 写操作后调用：debounce 一次同步。
  ///
  /// **不 await**：调用点（Provider 的写方法）已经写库成功，同步是后台行为。
  /// 调用点覆盖全部六张同步表（学生 / 小组 / 评分项 / 评分记录 / 课表 / 调休），
  /// 见各 Provider 里紧跟 `load*` 之后的那一行。
  void scheduleSync() {
    if (_client == null) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(syncNow()));
  }

  /// 立刻跑一轮 push + pull。
  ///
  /// 返回 null 表示跑完了；返回字符串表示"这一轮没跑成"，原因可直接展示。
  /// 之前这些分支都是静默 `return`，用户点「立即同步」时界面毫无反馈
  /// （按钮既不置忙、也不给任何提示），看起来像功能坏了。
  Future<String?> syncNow() async {
    final client = _client;
    if (client == null) return '尚未配对';
    if (_running) return '同步进行中，请稍后再试';
    if (DateTime.now().isBefore(_nextAttempt)) {
      return '刚失败过，${_nextAttempt.difference(DateTime.now()).inSeconds} 秒后重试';
    }

    // 需要用户决定时不要跑普通同步：那会在用户还没选之前就把两边的数据
    // 搅在一起，用户之后的"保留远端"就变成"在已经混过的数据上保留远端"。
    if (needsMergeDecision) return '首次同步需要先选择「合并 / 保留本地 / 保留远端」';

    _running = true;
    _setStatus(SyncStatus.syncing);
    final db = await DatabaseHelper.instance.database;
    final codec = SyncEventCodec(db);
    try {
      if (_initialState == InitialSyncState.pending) {
        await _runInitialSync(client, db, codec);
        // 会合中途要求用户决定：本轮到此为止，等 resolveInitialSync。
        if (needsMergeDecision) {
          return '首次同步需要先选择「合并 / 保留本地 / 保留远端」';
        }
      }
      await _push(client, db, codec);
      await _pull(client, db, codec);
      await _refreshPending(db);
      _lastSuccessAt = DateTime.now();
      // 有事件应用失败时保留 _lastError：链路是通的，但数据没全进来，
      // 状态上必须能看出来（_pull 已经把具体条数写进 _lastError）。
      if (_rejectedEvents == 0) _lastError = null;
      _failures = 0;
      _nextAttempt = DateTime.fromMillisecondsSinceEpoch(0);
      _setStatus(SyncStatus.idle);
      return null;
    } on SyncException catch (error) {
      _lastError = error.message;
      if (error.isUnauthorized) {
        _setStatus(SyncStatus.authRequired);
      } else {
        _failures++;
        _scheduleRetry();
        _setStatus(SyncStatus.offline);
      }
      return error.message;
    } catch (error) {
      _lastError = '$error';
      _failures++;
      _scheduleRetry();
      _setStatus(SyncStatus.error);
      return '$error';
    } finally {
      _running = false;
    }
  }

// ---- 首次会合 ----

  /// 首次配对后的会合。**自动执行**，但两端都有数据时会停下来等用户选。
  ///
  /// 三种情形：
  /// 1. 本地空、远端空 → 什么都不用做；
  /// 2. 本地有、远端空 → 把本地全部活行推上去（这就是"启用同步之前的数据"）；
  /// 3. 两端都有 → 记下对比，把状态置为需要用户选择，不擅自覆盖任何一边。
  Future<void> _runInitialSync(
    SyncClient client,
    Database db,
    SyncEventCodec codec,
  ) async {
    _initialBusy = true;
    notifyListeners();
    try {
      final localRows = await codec.countLocalRows();
      final summary = await client.summary();

      if (summary.isEmpty && localRows == 0) {
        await _markInitialDone(db);
        return;
      }
      if (summary.isEmpty) {
        await _uploadLocalSnapshot(client, db, codec, startRev: 0);
        await _markInitialDone(db);
        return;
      }
      if (localRows == 0) {
        // 本地空、远端有：直接拉快照铺满本地即可，不用问。
        await _pullSnapshot(db, codec, client);
        await _markInitialDone(db);
        return;
      }
      _mergePreview = InitialMergePreview(
        localRows: localRows,
        remoteRows: summary.totalLiveRows,
        remoteMaxRev: summary.maxRev,
      );
      _setStatus(SyncStatus.idle);
      notifyListeners();
    } finally {
      _initialBusy = false;
      notifyListeners();
    }
  }

  /// 用户选完之后继续会合。
  Future<String?> resolveInitialSync(MergeChoice choice) async {
    final client = _client;
    if (client == null) return '尚未配对';
    if (_running || _initialBusy) return '同步进行中，请稍后再试';
    _initialBusy = true;
    _running = true;
    _setStatus(SyncStatus.syncing);
    notifyListeners();
    final db = await DatabaseHelper.instance.database;
    final codec = SyncEventCodec(db);
    try {
      switch (choice) {
        case MergeChoice.merge:
          // 合并 = 双方都不丢：本地行用比服务端 max_rev 更大的 rev 推上去
          // （这样同 uid 的行按 LWW 收敛到本地版本），再拉快照把服务端独有的
          // 行带下来。结果是两边的并集。
          //
          // 注意：如果两边各加过"同一条"，合并后会有两条。这是 LWW 的固有
          // 局限——它不知道两条记录语义上是同一个。界面文案里已写明。
          await _uploadLocalSnapshot(
            client,
            db,
            codec,
            startRev: _mergePreview?.remoteMaxRev ?? 0,
          );
          await _pullSnapshot(db, codec, client);
        case MergeChoice.keepLocal:
          // 保留本地 = 本地为准，**服务端独有的行也要拉下来**（否则老师会说
          // "我选保留本地，结果之前从别的机器同步来的学生不见了"）。
          // 与 merge 的差别只在措辞上：merge 是"并集"，keepLocal 是"本地
          // 覆盖同名项后仍然收敛"，实际数据操作相同——因为 LWW 已经保证
          // 本地用更大 rev 赢过了同 uid 的行。
          await _uploadLocalSnapshot(
            client,
            db,
            codec,
            startRev: _mergePreview?.remoteMaxRev ?? 0,
          );
          await _pullSnapshot(db, codec, client);
        case MergeChoice.keepRemote:
          // 保留远端 = 服务端为准。先拉快照覆盖同 uid 的行，再把服务端上
          // 没有的本地行打墓碑（它们在界面上消失，但能被回收站找回）。
          // 这一步和 keepLocal 是真正对称的：各自把对方独有的行"作废"。
          await _pullSnapshot(db, codec, client);
          await _tombstoneRowsAbsentOnServer(db, codec, client);
      }
      await _markInitialDone(db);
      await _refreshPending(db);
      _lastSuccessAt = DateTime.now();
      _lastError = null;
      _failures = 0;
      _nextAttempt = DateTime.fromMillisecondsSinceEpoch(0);
      _setStatus(SyncStatus.idle);
      return null;
    } on SyncException catch (error) {
      _lastError = error.message;
      _setStatus(
        error.isUnauthorized ? SyncStatus.authRequired : SyncStatus.offline,
      );
      return '会合失败：${error.message}';
    } catch (error) {
      _lastError = '$error';
      _setStatus(SyncStatus.error);
      return '会合失败：$error';
    } finally {
      _running = false;
      _initialBusy = false;
      notifyListeners();
    }
  }

  /// 把本地所有活行推上去。
  ///
  /// 走的是普通 `/sync/push`，不另开一条通道：幂等、分批、断线重试
  /// 全都已经存在，这里只需要把事件造出来。
  Future<void> _uploadLocalSnapshot(
    SyncClient client,
    Database db,
    SyncEventCodec codec, {
    required int startRev,
  }) async {
    final deviceId = await _getState(db, 'device_id') ?? '';
    // startRev 必须严格大于服务端已知的最大 rev：否则上传的是"更旧的版本"，
    // 服务端物化表会拒绝更新，表现为"上传成功但服务端还是老数据"。
    final events = await codec.snapshotLocalRows(
      startRev: startRev,
      deviceId: deviceId,
    );
    if (events.isEmpty) return;
    // 顺手把本地 lamport 抬到这批 rev 之上，避免初始上传之后本地再写入
    // 拿到一个比刚上传的版本更小的号（那会让自己改不动自己刚推的数据）。
    if (events.isNotEmpty) {
      await db.rawUpdate(
        "UPDATE sync_state SET value = MAX(CAST(value AS INTEGER), ?) "
        "WHERE key = 'lamport'",
        [events.last.rev],
      );
    }
    for (var i = 0; i < events.length; i += pushBatch) {
      final chunk = events.sublist(
        i,
        (i + pushBatch).clamp(0, events.length),
      );
      await client.push(chunk);
    }
  }

  Future<void> _pullSnapshot(
    Database db,
    SyncEventCodec codec,
    SyncClient client,
  ) async {
    final page = await client.bootstrap();
    for (final event in page.events) {
      await codec.applyRemote(event);
    }
  }

  /// 保留远端时：把服务端上没有的本地行打成本地墓碑。
  Future<void> _tombstoneRowsAbsentOnServer(
    Database db,
    SyncEventCodec codec,
    SyncClient client,
  ) async {
    final remote = await client.bootstrap();
    final remoteKeys = {for (final e in remote.events) '${e.table}|${e.uid}'};
    final local = await codec.localLiveUids();
    for (final row in local) {
      if (remoteKeys.contains('${row.table}|${row.uid}')) continue;
      await codec.tombstoneLocally(row.table, row.uid);
    }
  }

  Future<void> _markInitialDone(Database db) async {
    await _setState(db, 'initial_sync_done', '1');
    _initialState = InitialSyncState.done;
    _mergePreview = null;
    notifyListeners();
  }

  // ---- 内部 ----

  Future<void> _push(SyncClient client, Database db, SyncEventCodec codec) async {
    while (true) {
      final events = await codec.readOutbox(limit: pushBatch);
      if (events.isEmpty) return;
      final response = await client.push(events);
      if (response.accepted == 0 &&
          response.duplicates == 0 &&
          response.rejected == 0) {
        // 服务端一条都没处理（既没接收、也没判重、也没拒收）：
        // 不是网络问题，是协议/数据问题，停下避免死循环。
        throw const SyncException('server rejected batch');
      }
      if (response.rejected > 0) {
        // 服务端逐条回滚掉了这些事件（未知表名 / 字段类型不对 / 畸形）。
        // 它们留在 outbox 里只会被无限重试，所以照常从队列删除，
        // 但把条数暴露出来 —— 否则就是"同步看着正常、数据悄悄少了"。
        _droppedOnPush += response.rejected;
        _lastError = '服务端拒收了 ${response.rejected} 条事件（已跳过）';
      }
      // 推送成功的事件从 outbox 删除。语义是「已经交给服务端」，
      // 而不是「对端已应用」——后者只能靠 pull 的 rev 收敛来证明。
      final seqs = events.map((e) => e.seq!).toList();
      await db.delete(
        'sync_outbox',
        where: 'seq IN (${List.filled(seqs.length, '?').join(',')})',
        whereArgs: seqs,
      );
      // 这里**绝不能**把 response.seq 写进 server_seq。
      //
      // 应答里的 seq 是服务端的**全局**最大序号，不是「我这一批」的序号：
      // 别的设备在此之前推过事件时，它已经指向那些事件之后了。拿它当拉取
      // 游标等于凭空跳过别人的改动，而且两端界面都正常、只是少了几条数据
      // （见 test/sync_cursor_test.dart）。
      //
      // server_seq 的唯一写入点是 _pull：真正拉到那一页，才算「看过」。
      if (events.length < pushBatch) return;
    }
  }

  /// 拉取增量事件。**server_seq 只在这里推进**。
  ///
  /// 游标语义是「我已经把 seq <= N 的事件全部应用过了」，所以游标只能推进到
  /// **最后一条成功应用**的事件上。
  ///
  /// 这里有一个两难，必须显式处理，不能靠"失败了也照推游标"糊过去：
  /// - 游标不前进 → 一条永远应用不成功的事件会让同步永久卡死，
  ///   后面所有设备的所有改动都进不来；
  /// - 游标照常前进 → 这条事件**再也不会被重放**，数据永久丢失，
  ///   而界面上只表现为"有 N 条事件无法应用"，下一轮就消失了。
  ///
  /// 处置：游标停在失败事件之前并原地重试；连续失败达到
  /// [maxApplyAttempts] 次才判定为毒事件、跳过并记进 `sync_dead_letters`，
  /// 让它在设置页一直可见，而不是悄悄消失。
  Future<void> _pull(SyncClient client, Database db, SyncEventCodec codec) async {
    var cursor = int.tryParse(await _getState(db, 'server_seq') ?? '0') ?? 0;
    _rejectedEvents = 0;
    await _ensureDeadLetterTable(db);
    while (true) {
      final page = await client.pull(since: cursor, limit: pullBatch);
      if (page.events.isEmpty) break;
      var advanced = cursor;
      var blocked = false;
      for (final event in page.events) {
        final seq = event.seq;
        try {
          await codec.applyRemote(event);
          if (seq != null) {
            advanced = seq;
            await _clearApplyFailure(db, seq);
          }
        } catch (error) {
          _rejectedEvents++;
          debugPrint('应用远端事件失败 $event：$error');
          if (seq == null) {
            // 没有 seq 就无处记账（pull 返回的事件一定带 seq）。
            _lastError = '有 $_rejectedEvents 条事件无法应用：$error';
            continue;
          }
          final attempts = await _bumpApplyFailure(db, seq);
          if (attempts < maxApplyAttempts) {
            // 还能重试：游标停在这条之前，本轮到此为止。
            _lastError =
                '有 $_rejectedEvents 条事件无法应用（第 $attempts 次重试）：$error';
            blocked = true;
            break;
          }
          // 判定为毒事件：跳过它，但留下可查的记录。
          await _recordDeadLetter(db, event, '$error');
          advanced = seq;
          await _clearApplyFailure(db, seq);
          _lastError = '有 1 条事件连续 $maxApplyAttempts 次无法应用，已跳过：$error';
        }
      }
      cursor = advanced;
      await _setState(db, 'server_seq', cursor.toString());
      if (blocked || !page.hasMore) break;
    }
  }

  /// 一条事件最多重试几次后被判定为毒事件。
  static const int maxApplyAttempts = 3;

  Future<void> _ensureDeadLetterTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_dead_letters (
        seq INTEGER PRIMARY KEY,
        tbl TEXT NOT NULL,
        uid TEXT NOT NULL,
        op TEXT NOT NULL,
        rev INTEGER NOT NULL,
        rev_device TEXT NOT NULL,
        error TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
  }

  /// 记一次应用失败，返回该事件累计失败次数。
  ///
  /// 计数存进 `sync_state`（JSON）而不是内存：进程重启后仍然有效——
  /// 一个每次启动都重新计数的计数器挡不住真正的毒事件。
  Future<int> _bumpApplyFailure(Database db, int seq) async {
    final map = await _readApplyFailures(db);
    final attempts = ((map['$seq'] as num?)?.toInt() ?? 0) + 1;
    map['$seq'] = attempts;
    await _setState(db, 'apply_failures', jsonEncode(map));
    return attempts;
  }

  Future<void> _clearApplyFailure(Database db, int seq) async {
    final map = await _readApplyFailures(db);
    if (map.remove('$seq') == null) return;
    await _setState(db, 'apply_failures', jsonEncode(map));
  }

  Future<Map<String, dynamic>> _readApplyFailures(Database db) async {
    final raw = await _getState(db, 'apply_failures');
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _recordDeadLetter(
    Database db,
    SyncEvent event,
    String error,
  ) async {
    await db.insert('sync_dead_letters', {
      'seq': event.seq ?? 0,
      'tbl': event.table,
      'uid': event.uid,
      'op': event.op.wire,
      'rev': event.rev,
      'rev_device': event.revDevice,
      'error': error,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全量对齐：把服务端上每一行的最新状态覆盖到本地。
  ///
  /// 与 [syncNow] 是互补关系，不是替代关系——
  /// [syncNow] 走事件流（快、增量），这个方法走快照（慢、但能修复
  /// 「游标坏了 / 本地被还原过」这类事件流补不回来的情况）。
  ///
  /// 注意它**不推进 server_seq**：快照没有 seq 语义，推进游标会让中间那段
  /// 事件被永久跳过。这里只借它完成「把远端当前值铺到本地」。
  Future<String?> bootstrapFromServer() async {
    final client = _client;
    if (client == null) return '尚未配对，无法全量对齐';
    if (_running) return '同步进行中，请稍后再试';
    _running = true;
    _setStatus(SyncStatus.syncing);
    final db = await DatabaseHelper.instance.database;
    final codec = SyncEventCodec(db);
    try {
      final page = await client.bootstrap();
      var applied = 0;
      var failed = 0;
      for (final event in page.events) {
        // 逐条容错：一份快照里混着一条坏行，不该让整次"唯一修复出口"失败。
        try {
          if (await codec.applyRemote(event)) applied++;
        } catch (error) {
          failed++;
          debugPrint('全量对齐时跳过一条无法应用的事件 $event：$error');
        }
      }
      // ---- 修掉"事件流补不回来的"两类残留 ----
      //
      // 1) 游标：文档让用户在"游标坏了、数据看着不对"时点这个按钮，而这里
      //    之前既不推进也不重置 server_seq —— 点完之后下一轮 _pull 还从那个
      //    坏游标继续，中间那段事件永久跳过，"全量对齐"等于什么都没修。
      //    快照已经是服务端的全量最新状态，把游标抬到当前的 max_seq 是安全的。
      //
      // 2) outbox：快照用远端值覆盖了本地，此前排队未推的本地事件如果继续
      //    推上去，会把刚被覆盖掉的旧值**反向推回服务端**。既然用户明确选择
      //    "以服务端为准"，这批事件就该作废；否则对齐完立刻又不一致。
      final maxSeq = page.seq;
      await _setState(db, 'server_seq', '$maxSeq');
      await db.delete('sync_outbox');
      await db.delete('sync_dead_letters');
      await _setState(db, 'apply_failures', '{}');
      _rejectedEvents = 0;
      _lastSuccessAt = DateTime.now();
      _lastError = null;
      _failures = 0;
      _nextAttempt = DateTime.fromMillisecondsSinceEpoch(0);
      await _refreshPending(db);
      _setStatus(SyncStatus.idle);
      // applied 只用于日志：全量对齐的成功判据是"跑完且没抛异常"，
      // 而不是"改了几行"（快照里绝大多数行本来就一致）。
      debugPrint('全量对齐完成：$applied 行有变化，$failed 行被跳过');
      return failed == 0 ? null : '全量对齐完成，但有 $failed 行无法应用';
    } on SyncException catch (error) {
      _lastError = error.message;
      _setStatus(
        error.isUnauthorized ? SyncStatus.authRequired : SyncStatus.offline,
      );
      return '全量对齐失败：${error.message}';
    } catch (error) {
      _lastError = '$error';
      _setStatus(SyncStatus.error);
      return '全量对齐失败：$error';
    } finally {
      _running = false;
    }
  }

  Future<void> _refreshPending(Database db) async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM sync_outbox');
    _pendingCount = (rows.first['n'] as int?) ?? 0;

    // 占位行的特征：活着的、名字为空、uid 以占位前缀开头（见 _insertPlaceholder）。
    // 学号同理，用 '~pending~' 打头。
    var placeholders = 0;
    for (final table in const ['groups', 'students', 'score_items']) {
      final found = await db.rawQuery(
        "SELECT COUNT(*) AS n FROM $table "
        "WHERE deleted_at IS NULL AND (name IS NULL OR name = '')",
      );
      placeholders += (found.first['n'] as int?) ?? 0;
    }
    _orphanPlaceholders = placeholders;
  }

  void _scheduleRetry() {
    final seconds = min(300, 5 * pow(2, min(_failures, 6)).toInt());
    _nextAttempt = DateTime.now().add(Duration(seconds: seconds));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeat, (_) => unawaited(syncNow()));
  }

  Future<String> _ensureDeviceId(Database db) async {
    final existing = await _getState(db, 'device_id');
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final suffix = List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final id = 'dev_$suffix';
    await _setState(db, 'device_id', id);
    return id;
  }

  Future<String?> _getState(Database db, String key) async {
    final rows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _setState(Database db, String key, String value) async {
    await db.insert('sync_state', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  void _setStatus(SyncStatus status) {
    if (_status == status) {
      notifyListeners();
      return;
    }
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _debounceTimer?.cancel();
    _client?.close();
    super.dispose();
  }
}