import 'package:flutter/foundation.dart';

import '../sync/sync_engine.dart';

/// 把 [SyncEngine] 暴露给 UI。
///
/// 引擎本身是单例（同步不能随页面销毁而停），Provider 只做一层转发，
/// 好处是页面可以照常 `context.watch<SyncProvider>()`，与其余 7 个 Provider 一致。
class SyncProvider extends ChangeNotifier {
  SyncProvider() {
    SyncEngine.instance.addListener(_forward);
  }

  void _forward() => notifyListeners();

  SyncEngine get engine => SyncEngine.instance;

  SyncStatus get status => SyncEngine.instance.status;
  bool get isConfigured => SyncEngine.instance.isConfigured;
  DateTime? get lastSuccessAt => SyncEngine.instance.lastSuccessAt;
  int get pendingCount => SyncEngine.instance.pendingCount;
  int get orphanPlaceholders => SyncEngine.instance.orphanPlaceholders;
  int get rejectedEvents => SyncEngine.instance.rejectedEvents;

  /// 累计被丢弃的事件数（不可编码 + 被服务端逐条拒收）。
  int get droppedEvents => SyncEngine.instance.droppedEvents;
  String? get lastError => SyncEngine.instance.lastError;

  Future<void> init() => SyncEngine.instance.configure();

  /// 配对。成功返回 null，失败返回可直接展示给用户的原因。
  Future<String?> pair({
    required String serverUrl,
    required String code,
    String? caPemPath,
  }) => SyncEngine.instance.pair(
    serverUrl: serverUrl,
    code: code,
    caPemPath: caPemPath,
  );

  Future<void> unpair() => SyncEngine.instance.unpair();

  /// 返回 null 表示跑完了；否则是可展示的失败原因。
  Future<String?> syncNow() => SyncEngine.instance.syncNow();

  /// 全量对齐（拉服务端快照覆盖本地）。失败返回可直接展示的原因。
  Future<String?> bootstrapFromServer() =>
      SyncEngine.instance.bootstrapFromServer();

  /// 首次会合是否还在等用户决定（两端都有数据时）。
  bool get needsMergeDecision => SyncEngine.instance.needsMergeDecision;

  /// 等用户决定时的两端对比。
  InitialMergePreview? get mergePreview => SyncEngine.instance.mergePreview;

  /// 会合/上传是否正在进行。
  bool get initialBusy => SyncEngine.instance.initialBusy;

  /// 用户三选一之后继续会合。成功返回 null。
  Future<String?> resolveInitialSync(MergeChoice choice) =>
      SyncEngine.instance.resolveInitialSync(choice);

  /// 服务端地址（设置页回显用；来自引擎的内存缓存，不查库）。
  String get serverUrl => SyncEngine.instance.serverUrl;

  @override
  void dispose() {
    SyncEngine.instance.removeListener(_forward);
    super.dispose();
  }
}