/// 花名册 AI 自动选中学生 —— 规则模型。
///
/// 用户在处理页选择"哪些标记代表需要选中学生"，支持多选与自定义文字规则。
/// 互斥组：
/// - {blank, anyMark}: 「空白」与「有手写内容」互斥
/// - {threshold:atLeast, threshold:below}: 分数阈值两档互斥
enum RosterMark {
  /// 打勾 ✓
  check,

  /// 打叉 ×
  cross,

  /// 三角形 △（如"订正"图例）
  triangle,

  /// 空白：格内无任何手写内容
  blank,

  /// 有手写内容：任意笔迹（含分数数字）
  anyMark,
}

/// 分数阈值规则（格内是数字时按数值比较）。
enum ScoreThreshold {
  /// 未设置
  none,

  /// 分数 ≥ 阈值
  atLeast,

  /// 分数 < 阈值
  below,
}

/// 一次 AI 选学生规则。
class AiSelectionRule {
  /// 选中标记集合（多选）。
  final Set<RosterMark> marks;

  /// 分数阈值类型。
  final ScoreThreshold scoreThreshold;

  /// 分数阈值数值（[scoreThreshold] != none 时有效）。
  final double scoreValue;

  /// 自定义文字规则（追加进提示词，可为空）。
  final String customInstruction;

  const AiSelectionRule({
    required this.marks,
    this.scoreThreshold = ScoreThreshold.none,
    this.scoreValue = 60,
    this.customInstruction = '',
  });

  /// 互斥组定义：同一组内的规则项不可同时选中。
  ///
  /// 用字符串标识规则项（mark:check / threshold:atLeast ...），
  /// 便于同时表达 [RosterMark] 与 [ScoreThreshold] 的互斥。
  static const List<List<String>> exclusiveGroups = [
    ['mark:blank', 'mark:anyMark'],
    ['threshold:atLeast', 'threshold:below'],
  ];

  /// 返回勾选 [key] 后需要自动取消的项（同互斥组内的其它已选项）。
  static List<String> conflictsWhenSelecting(Set<String> selected, String key) {
    final result = <String>[];
    for (final group in exclusiveGroups) {
      if (!group.contains(key)) continue;
      for (final other in group) {
        if (other != key && selected.contains(other)) {
          result.add(other);
        }
      }
    }
    return result;
  }

  /// 判断分数值是否满足当前阈值规则。不适用阈值时返回 null。
  bool? matchesScore(double value) {
    switch (scoreThreshold) {
      case ScoreThreshold.none:
        return null;
      case ScoreThreshold.atLeast:
        return value >= scoreValue;
      case ScoreThreshold.below:
        return value < scoreValue;
    }
  }

  /// 渲染为提示词规则段（中文自然语言）。
  String toPrompt() {
    final parts = <String>[];
    for (final m in marks) {
      switch (m) {
        case RosterMark.check:
          parts.add('格内有打勾（勾号）');
          break;
        case RosterMark.cross:
          parts.add('格内有打叉（叉号）');
          break;
        case RosterMark.triangle:
          parts.add('格内有三角形');
          break;
        case RosterMark.blank:
          parts.add('格内是空白的（无任何手写内容）');
          break;
        case RosterMark.anyMark:
          parts.add('格内有任意手写内容（包括数字分数）');
          break;
      }
    }
    if (scoreThreshold == ScoreThreshold.atLeast) {
      parts.add('格内手写数字 ≥ $scoreValue');
    } else if (scoreThreshold == ScoreThreshold.below) {
      parts.add('格内手写数字 < $scoreValue');
    }
    final custom = customInstruction.trim();
    if (custom.isNotEmpty) {
      parts.add('额外条件：$custom');
    }
    if (parts.isEmpty) {
      return '（用户未选择具体规则，按所有"有手写内容"的格子理解）';
    }
    return '满足以下任意一条即视为命中：${parts.join('；')}';
  }

  /// 是否需要模型转录数值（提示词分支）。
  bool get needsScoreTranscription =>
      scoreThreshold != ScoreThreshold.none ||
      customInstruction.trim().isNotEmpty;

  AiSelectionRule copyWith({
    Set<RosterMark>? marks,
    ScoreThreshold? scoreThreshold,
    double? scoreValue,
    String? customInstruction,
  }) {
    return AiSelectionRule(
      marks: marks ?? this.marks,
      scoreThreshold: scoreThreshold ?? this.scoreThreshold,
      scoreValue: scoreValue ?? this.scoreValue,
      customInstruction: customInstruction ?? this.customInstruction,
    );
  }

  Map<String, dynamic> toMap() => {
    'marks': marks.map((m) => m.name).toList(),
    'scoreThreshold': scoreThreshold.name,
    'scoreValue': scoreValue,
    'customInstruction': customInstruction,
  };

  factory AiSelectionRule.fromMap(Map<String, dynamic> map) {
    final markNames = (map['marks'] as List?)?.cast<String>() ?? const [];
    return AiSelectionRule(
      marks: markNames
          .map((n) => RosterMark.values.firstWhere(
              (m) => m.name == n, orElse: () => RosterMark.check))
          .toSet(),
      scoreThreshold: ScoreThreshold.values.firstWhere(
        (t) => t.name == (map['scoreThreshold'] as String?),
        orElse: () => ScoreThreshold.none,
      ),
      scoreValue: (map['scoreValue'] as num?)?.toDouble() ?? 60,
      customInstruction: (map['customInstruction'] as String?) ?? '',
    );
  }
}
