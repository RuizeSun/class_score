/// 桌面课表条的展示阶段。
///
/// 桌面条只有一块内容区，同一时刻只呈现一种外观；这里把「看图说话」的六种
/// 画面收敛成一个枚举，UI 层只按 [DesktopSchedulePhase] 分派渲染，不再自己
/// 判断时间——时间判断全部集中在 `ScheduleTimelineService` 里，便于单测。
enum DesktopSchedulePhase {
  /// 今天无课（课表为空 / 调休放假）：只显示天气与空状态。
  restDay,

  /// 首节课之前（距离上课还很远）：只显示课程列表，不显示状态块。
  beforeFirst,

  /// 上课中（图六）：状态块显示「课程名 -Nmin」+ 课程进度条。
  inClass,

  /// 课间休息（图一）：状态块显示「课间休息 -Nmin」+ 课间进度条。
  breakTime,

  /// 全部课程已结束：只显示课程列表，不显示状态块。
  afterLast,

  /// 临近上课提示（图二）：整条变蓝底「ⓘ 即将上课 🚪」，短暂显示。
  preAlert,

  /// 上课倒计时（图三 ↔ 图四交替）：背景为倒计时进度条。
  preCountdown,

  /// 正式上课提示（图五）：整条变蓝底「ⓘ 上课 🚪」，短暂显示后转入 [inClass]。
  classNotice,
}

/// 时间线上的一节课。
///
/// 课表数据只有「开始 / 结束时间」，没有节次概念，因此一节课就是一节；
/// 两节课之间的空隙即课间休息（不区分上午 / 下午）。
class ScheduleSlot {
  const ScheduleSlot({
    required this.courseName,
    required this.start,
    required this.end,
  });

  final String courseName;

  /// 当天该节课的开始时刻（含日期）。
  final DateTime start;

  /// 当天该节课的结束时刻（含日期）。
  final DateTime end;

  Duration get duration => end.difference(start);

  /// 「11:30」
  static String formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  /// 「11:30-12:10」
  String get timeRange => '${formatTime(start)}-${formatTime(end)}';

  Map<String, dynamic> toJson() => {
    'course_name': courseName,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
  };

  factory ScheduleSlot.fromJson(Map<String, dynamic> json) => ScheduleSlot(
    courseName: json['course_name'] as String,
    start: DateTime.parse(json['start'] as String),
    end: DateTime.parse(json['end'] as String),
  );
}

/// 某一时刻桌面条应当呈现的完整状态。
///
/// [phaseStart] / [phaseEnd] 只描述「当前阶段的进度条区间」：
/// - 上课中 = 本节课的起止（图六里蓝色进度条就是课程进度）；
/// - 课间休息 = 上节课结束 → 下节课开始（课间进度）；
/// - 临近上课 / 倒计时 = 提醒窗口起点 → 正式上课时刻。
///
/// 这样进度条永远等于 `(now - phaseStart) / (phaseEnd - phaseStart)`，
/// UI 不需要再各自换算。
class DesktopScheduleState {
  const DesktopScheduleState({
    required this.phase,
    required this.slots,
    required this.now,
    this.currentSlot,
    this.nextSlot,
    this.phaseStart,
    this.phaseEnd,
  });

  final DesktopSchedulePhase phase;

  /// 今日课程（按开始时间升序）。
  final List<ScheduleSlot> slots;

  /// 当前这一节课：上课中 / 上课提示时非空。
  final ScheduleSlot? currentSlot;

  /// 下一节课：课间休息 / 临近上课 / 倒计时时非空。
  final ScheduleSlot? nextSlot;

  final DateTime now;
  final DateTime? phaseStart;
  final DateTime? phaseEnd;

  /// 当前阶段剩余时间（倒计时文案取它）。
  Duration get remaining {
    final end = phaseEnd;
    if (end == null) return Duration.zero;
    final left = end.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// 当前阶段总时长（进度条分母）。
  Duration get phaseTotal {
    final start = phaseStart;
    final end = phaseEnd;
    if (start == null || end == null) return Duration.zero;
    return end.difference(start);
  }

  /// 当前阶段进度 0.0 - 1.0（进度条 / 背景填充比例）。
  double get progress {
    final total = phaseTotal.inMilliseconds;
    if (total <= 0) return 0;
    final elapsed = now.difference(phaseStart!).inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  /// 是否处于「上课中」语义（含刚开始的提示阶段）——决定状态块配色。
  bool get isInClass =>
      phase == DesktopSchedulePhase.inClass ||
      phase == DesktopSchedulePhase.classNotice;

  /// 是否需要把整条切换成提示 / 倒计时外观。
  bool get isOverlay =>
      phase == DesktopSchedulePhase.preAlert ||
      phase == DesktopSchedulePhase.preCountdown ||
      phase == DesktopSchedulePhase.classNotice;

  DesktopScheduleState copyWith({
    DesktopSchedulePhase? phase,
    List<ScheduleSlot>? slots,
    ScheduleSlot? currentSlot,
    ScheduleSlot? nextSlot,
    DateTime? now,
    DateTime? phaseStart,
    DateTime? phaseEnd,
  }) {
    return DesktopScheduleState(
      phase: phase ?? this.phase,
      slots: slots ?? this.slots,
      currentSlot: currentSlot ?? this.currentSlot,
      nextSlot: nextSlot ?? this.nextSlot,
      now: now ?? this.now,
      phaseStart: phaseStart ?? this.phaseStart,
      phaseEnd: phaseEnd ?? this.phaseEnd,
    );
  }

  /// 跨窗口（主窗口 → 桌面浮窗）推送用的快照。
  Map<String, dynamic> toJson() => {
    'phase': phase.name,
    'slots': slots.map((slot) => slot.toJson()).toList(),
    if (currentSlot != null) 'current_slot': currentSlot!.toJson(),
    if (nextSlot != null) 'next_slot': nextSlot!.toJson(),
    'now': now.toIso8601String(),
    if (phaseStart != null) 'phase_start': phaseStart!.toIso8601String(),
    if (phaseEnd != null) 'phase_end': phaseEnd!.toIso8601String(),
  };

  factory DesktopScheduleState.fromJson(Map<String, dynamic> json) {
    final current = json['current_slot'];
    final next = json['next_slot'];
    final phaseStart = json['phase_start'] as String?;
    final phaseEnd = json['phase_end'] as String?;
    return DesktopScheduleState(
      phase: DesktopSchedulePhase.values.firstWhere(
        (value) => value.name == json['phase'],
        orElse: () => DesktopSchedulePhase.restDay,
      ),
      slots: asList(json['slots'])
          .map((item) => ScheduleSlot.fromJson(asStringKeyedMap(item)))
          .toList(),
      currentSlot: current == null
          ? null
          : ScheduleSlot.fromJson(asStringKeyedMap(current)),
      nextSlot: next == null
          ? null
          : ScheduleSlot.fromJson(asStringKeyedMap(next)),
      now: DateTime.parse(json['now'] as String),
      phaseStart: phaseStart == null ? null : DateTime.parse(phaseStart),
      phaseEnd: phaseEnd == null ? null : DateTime.parse(phaseEnd),
    );
  }
}

/// 把平台通道传回的嵌套结构转成 `Map<String, dynamic>`。
///
/// 为什么需要：`StandardMethodCodec` 解码后嵌套 Map 的实际类型是
/// `Map<Object?, Object?>`，直接 `as Map<String, dynamic>` 会抛
/// 「type `_Map<Object?, Object?>` is not a subtype of type `Map<String, dynamic>`」。
/// 顶层转换过、嵌套层没转的话，解析 `slots` 时就会崩——而崩溃发生在浮窗引擎里，
/// 表现为「主窗口推送内容失败」，很难定位。
Map<String, dynamic> asStringKeyedMap(Object? value) {
  if (value is Map) {
    return value.map(
      (key, item) => MapEntry(key.toString(), _convert(item)),
    );
  }
  return const {};
}

/// 含嵌套的 `List`：逐个元素做同样的转换。
List<Object?> asList(Object? value) {
  if (value is List) return value.map(_convert).toList();
  return const [];
}

Object? _convert(Object? value) {
  if (value is Map) return asStringKeyedMap(value);
  if (value is List) return asList(value);
  return value;
}
