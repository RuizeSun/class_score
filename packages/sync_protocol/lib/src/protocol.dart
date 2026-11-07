/// 同步协议版本：破坏性改动时递增，服务端会拒绝版本不一致的客户端。
const int syncProtocolVersion = 1;

/// `rev` 的合法上限。
///
/// `rev` 是 **Lamport 逻辑时钟**，由客户端自行编号，服务端只做 LWW 比较。
/// 它必须是"单调递增的小整数"，不能是任意 int64：
///
/// 1. 服务端 `nextEventRev()` 用 `MAX(rev) + 1` 给管理员编辑取号。若某个设备
///    推来 `rev = 2^63-1`，`+1` 在 Dart 里**回绕成负数**（实测
///    `9223372036854775807 + 1 == -9223372036854775808`），此后管理员编辑
///    与所有设备的正常更新都会拿到负号，在 LWW 里**永久输给那条毒事件**，
///    而且没有任何界面能看出原因；
/// 2. 客户端抬 lamport 走的是 SQL `CAST(value AS INTEGER) + 1`，
///    超过 int64 后 SQLite 会退化成 REAL 并存成浮点字符串
///    `'9.22337203685478e+18'`，该设备的 Lamport 时钟从此损坏。
///
/// 取 2^53（JS 安全整数上限）：比任何真实课堂的写入次数大十几个数量级，
/// 又离 int64 悬崖有足够距离。正常设备永远碰不到它。
const int maxSafeRev = 9007199254740992; // 2^53

/// `rev` 是否在可安全参与 LWW 的范围内。
///
/// 下界取 1：`rev = 0` 是"从未同步过的行"的初始值，不该出现在事件流里。
bool isSafeRev(int rev) => rev >= 1 && rev <= maxSafeRev;

/// 同步端点路径。
class SyncPaths {
  static const String health = '/health';
  static const String pair = '/pair';
  static const String push = '/sync/push';
  static const String pull = '/sync/pull';

  /// 全量最新状态（新设备接管用；不参与 seq 游标）。
  static const String bootstrap = '/sync/bootstrap';

  /// 轻量摘要：各表行数、事件条数、最大 rev。
  ///
  /// 首次配对时用它判断"服务端是不是空的"，从而决定要不要把本地历史数据
  /// 一次性推上去、以及要不要让用户选保留哪一边。不直接复用 /sync/bootstrap
  /// 是因为那个要传每行的完整内容，而这里只需要几个计数。
  static const String summary = '/sync/summary';
}

/// 参与同步的表描述。
///
/// [columns] 是参与同步的列（不含本地自增 id、不含同步元数据）；
/// [foreignKeys] 描述哪些列存的是"另一个表的本地 id"，推送时要翻译成 uid。
/// 本表内部唯一、但**跨设备不唯一**的列该怎么协调。
///
/// 唯一索引只在一台设备内部成立：两台设备各自离线时，完全可能给不同对象
/// 分配同一个值（最典型的是"下一个空学号"）。合并时远端那条会撞唯一索引。
enum UniqueConflictPolicy {
  /// 保留这一行，把值改写成一个不冲突的（用于人的身份：学生不能因为
  /// 学号撞了就被丢掉）。
  renumber,

  /// 语义上不允许并存（比如"某一天的调休"只有一条），按 rev 裁决，
  /// 输的那条直接丢弃。
  preferLatest,
}

/// 参与同步的表描述。
///
/// 所有参与同步的表都必须有一个自增整数 `id`：同步元数据（uid / rev /
/// rev_device）靠它定位具体那一行。`app_settings` 原本以 `key` 为主键，
/// v11 迁移会把它补齐成 `id + key UNIQUE`，从而满足这个不变式。
class SyncTableSpec {
  const SyncTableSpec({
    required this.name,
    required this.columns,
    this.foreignKeys = const [],
    this.uidPrefix = 'row',
    this.localUnique = const [],
  });

  /// 表名。
  final String name;

  /// 参与同步的业务列。
  final List<String> columns;

  /// 外键列 → 目标表。
  final List<SyncForeignKey> foreignKeys;

  /// 自动生成 uid 时使用的前缀（便于人肉排查）。
  final String uidPrefix;

  /// 表内唯一但跨设备可能冲突的列。
  final List<SyncUniqueColumn> localUnique;


}

/// 一个"表内唯一"的列及其冲突处理策略。
class SyncUniqueColumn {
  const SyncUniqueColumn(this.column, this.policy);
  final String column;
  final UniqueConflictPolicy policy;
}

/// 一个外键列。
///
/// 推送时：把本地 id 换成目标的 uid，写到 [payloadKey]；
/// 拉取时：把 [payloadKey] 里的 uid 换回本地 id，写回 [column]。
class SyncForeignKey {
  const SyncForeignKey({
    required this.column,
    required this.targetTable,
    required this.payloadKey,
  });

  final String column;
  final String targetTable;
  final String payloadKey;
}

/// `score_records.target_id` 的多态外键：目标表由 `target_type` 决定。
const String scoreRecordTargetColumn = 'target_id';
const String scoreRecordTypeColumn = 'target_type';
const String scoreRecordTargetUidKey = 'target_uid';

/// `target_type` → 实际表名。
///
/// 历史原因两者不同名：库里存的是单数 `'student'` / `'group'`，
/// 而表名是复数。写库时曾经直接把前者当表名用（→ `no such table: student`），
/// 因此这里显式给出映射，推送与拉取两个方向共用。
String? scoreTargetTable(String? targetType) => switch (targetType) {
  'student' => 'students',
  'group' => 'groups',
  _ => null,
};

/// app_settings 里**参与同步**的键（白名单）。
///
/// 只收"影响算分结果"的配置。外观/硬件/安全相关的键一律排除：
/// - 外观：主题色、分栏比例、悬浮课表几何、天气
/// - 安全：pin_hash、usb_keys
/// - 本机行为：托盘、锁定、开机自启
const Set<String> syncedSettingKeys = {
  // 当前周期：不同步的话，大屏切到第 2 周期后老师端还在看第 1 周期
  'current_period',
  // 计分规则的三个核心值
  'student_initial_score',
  'group_initial_score',
  'group_score_mode',
  // 分数范围限制
  'score_range_mode',
  'score_range_min',
  'score_range_max',
  // 名次展示规则（影响报表看起来是否一致）
  'merge_same_rank',
  'competition_ranking',
  // 默认快速评分
  'default_quick_scoring',
};

/// 某个设置键是否参与同步。
bool isSyncedSettingKey(String key) => syncedSettingKeys.contains(key);

/// 全部参与同步的表。
const List<SyncTableSpec> syncTableSpecs = [
  SyncTableSpec(name: 'groups', columns: ['name'], uidPrefix: 'grp'),
  SyncTableSpec(
    name: 'students',
    columns: ['name', 'student_number', 'group_id', 'include_in_group_total'],
    foreignKeys: [
      SyncForeignKey(
        column: 'group_id',
        targetTable: 'groups',
        payloadKey: 'group_uid',
      ),
    ],
    uidPrefix: 'stu',
    // 学号在**一台设备内**唯一。两台设备离线时可能各给不同学生分配了同一个
    // 学号（都从"下一个空号"开始算），合并时必须保住两个人，于是把晚到的
    // 那一个改号；丢掉学生的代价远大于学号不连续。
    localUnique: [
      SyncUniqueColumn('student_number', UniqueConflictPolicy.renumber),
    ],
  ),
  SyncTableSpec(
    name: 'score_items',
    columns: ['name', 'default_score', 'description'],
    uidPrefix: 'itm',
  ),
  SyncTableSpec(
    name: 'score_records',
    columns: [
      'target_type',
      'target_id',
      'score',
      'reason',
      'score_item_id',
      'custom_name',
      'create_time',
      'period',
      'is_quick',
    ],
    foreignKeys: [
      SyncForeignKey(
        column: 'score_item_id',
        targetTable: 'score_items',
        payloadKey: 'score_item_uid',
      ),
    ],
    uidPrefix: 'rec',
  ),
  SyncTableSpec(
    name: 'course_schedule',
    columns: ['weekday', 'course_name', 'start_time', 'end_time'],
    uidPrefix: 'crs',
  ),

  // 计分规则与当前周期。
  //
  // 这些值直接决定"同一个班在两台机器上算出多少分"，不同步的话老师端看到的
  // 分数永远和大屏对不上（实测：改 3 个设置项产生 0 条事件）。
  //
  // 但 app_settings 里还混着**本机外观**（主题色、悬浮课表位置、天气城市……），
  // 那些绝不能跟着跑：两台机器屏幕尺寸不同，同步只会互相打架。
  // 因此按 [syncedSettingKeys] 白名单挑，而不是整表同步。
  SyncTableSpec(
    name: 'app_settings',
    columns: ['key', 'value'],
    uidPrefix: 'set',
    // key 是主键：两端都改同一个 key 时按 rev 裁决，不允许并存。
    localUnique: [
      SyncUniqueColumn('key', UniqueConflictPolicy.preferLatest),
    ],
  ),
  SyncTableSpec(
    name: 'schedule_adjustment',
    columns: ['date', 'weekday', 'created_at'],
    uidPrefix: 'adj',
    // 同一天只能有一条调休：两端口径不一致时按 rev 裁决，输的直接丢弃。
    localUnique: [
      SyncUniqueColumn('date', UniqueConflictPolicy.preferLatest),
    ],
  ),
];

/// 按表名取描述。
SyncTableSpec? syncTableSpec(String table) {
  for (final spec in syncTableSpecs) {
    if (spec.name == table) return spec;
  }
  return null;
}
