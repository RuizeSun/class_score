import 'protocol.dart';

/// 同步事件的操作类型。
enum SyncOp {
  upsert,
  delete;

  static SyncOp fromWire(String raw) =>
      raw == 'delete' ? SyncOp.delete : SyncOp.upsert;

  String get wire => name;
}

/// 一条同步事件：以"行"为粒度，不是"列"。
///
/// 之所以不做列级冲突合并：本应用的业务更新几乎都是整行语义（改名、换组、
/// 改分值），列级合并会制造出"一半新一半旧"的行，比 LWW 更难解释。
class SyncEvent {
  const SyncEvent({
    required this.table,
    required this.uid,
    required this.op,
    required this.rev,
    required this.revDevice,
    this.data,
    this.seq,
  });

  /// 表名（见 [syncTableSpecs]）。
  final String table;

  /// 行 uid（全局唯一，客户端生成，跨设备稳定）。
  final String uid;

  final SyncOp op;

  /// 逻辑版本号（设备单调计数，**不是**挂钟时间）。
  final int rev;

  /// 产生该版本的设备 id，用于 rev 打平时的确定性裁决。
  final String revDevice;

  /// 行内容（[SyncOp.delete] 时为 null）。外键已翻译成 uid。
  final Map<String, dynamic>? data;

  /// 服务端分配的全局递增序号（仅拉取时有值）。
  final int? seq;

  Map<String, dynamic> toJson() => {
    't': table,
    'u': uid,
    'o': op.wire,
    'r': rev,
    'd': revDevice,
    if (data != null) 'x': data,
    if (seq != null) 's': seq,
  };

  static SyncEvent fromJson(Map<String, dynamic> json) => SyncEvent(
    table: json['t'] as String,
    uid: json['u'] as String,
    op: SyncOp.fromWire((json['o'] as String?) ?? 'upsert'),
    rev: (json['r'] as num).toInt(),
    revDevice: (json['d'] as String?) ?? '',
    data: (json['x'] as Map?)?.cast<String, dynamic>(),
    seq: (json['s'] as num?)?.toInt(),
  );

  @override
  String toString() =>
      'SyncEvent($table/$uid rev=$rev by $revDevice ${op.wire})';
}

/// 服务端对一次 push 的应答。
class PushResponse {
  const PushResponse({
    required this.accepted,
    required this.duplicates,
    required this.seq,
    this.rejected = 0,
  });

  final int accepted;
  final int duplicates;

  /// 服务端逐条拒收的事件数（未知表名 / 字段类型不对 / 畸形事件）。
  ///
  /// 服务端会把这一条单独回滚掉并继续处理同批其它事件，而不是整批 500 ——
  /// 否则一条坏事件会让整批永远推不上去。客户端据此把这条从 outbox 删掉
  /// 并计入可见的失败计数，而不是无限重试。
  final int rejected;

  /// push 完成后服务端的最大 seq，客户端可据此直接推进游标。
  final int seq;

  static PushResponse fromJson(Map<String, dynamic> json) => PushResponse(
    accepted: (json['accepted'] as num?)?.toInt() ?? 0,
    duplicates: (json['duplicates'] as num?)?.toInt() ?? 0,
    seq: (json['seq'] as num?)?.toInt() ?? 0,
    rejected: (json['rejected'] as num?)?.toInt() ?? 0,
  );
}
