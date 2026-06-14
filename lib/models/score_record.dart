class ScoreRecord {
  final int? id;
  final String targetType; // 'group' or 'student'
  final int targetId;
  final double score;
  final String? reason;
  final String createTime;
  final int period; // 评分周期，默认从1开始

  ScoreRecord({
    this.id,
    required this.targetType,
    required this.targetId,
    required this.score,
    this.reason,
    required this.createTime,
    this.period = 1,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'target_type': targetType,
      'target_id': targetId,
      'score': score,
      'reason': reason,
      'create_time': createTime,
      'period': period,
    };
  }

  factory ScoreRecord.fromMap(Map<String, dynamic> map) {
    return ScoreRecord(
      id: map['id'] as int?,
      targetType: map['target_type'] as String,
      targetId: map['target_id'] as int,
      score: (map['score'] as num).toDouble(),
      reason: map['reason'] as String?,
      createTime: map['create_time'] as String,
      period: (map['period'] as int?) ?? 1,
    );
  }
}
