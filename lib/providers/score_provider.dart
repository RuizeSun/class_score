import 'package:flutter/foundation.dart';
import '../models/score_record.dart';
import '../database/database_helper.dart';
import '../services/backup_service.dart';

class ScoreProvider extends ChangeNotifier {
  List<ScoreRecord> _records = [];
  List<ScoreRecord> get records => _records;

  List<Map<String, dynamic>> _recordsWithName = [];
  List<Map<String, dynamic>> get recordsWithName => _recordsWithName;

  // Statistics data
  List<Map<String, dynamic>> _groupTotalScores = [];
  List<Map<String, dynamic>> get groupTotalScores => _groupTotalScores;

  List<Map<String, dynamic>> _studentTotalScores = [];
  List<Map<String, dynamic>> get studentTotalScores => _studentTotalScores;

  int? _filterGroupId;
  int? get filterGroupId => _filterGroupId;

  Future<void> loadRecords({String? targetType, int? targetId}) async {
    final maps = await DatabaseHelper.instance.getScoreRecords(
      targetType: targetType,
      targetId: targetId,
    );
    _recordsWithName = maps;
    _records = maps.map((m) => ScoreRecord.fromMap(m)).toList();
    notifyListeners();
  }

  Future<void> addScoreRecord({
    required String targetType,
    required int targetId,
    required double score,
    String? reason,
    int? scoreItemId,
    String? customName,
  }) async {
    await BackupService.instance.createBackup();
    final map = <String, dynamic>{
      'target_type': targetType,
      'target_id': targetId,
      'score': score,
      'reason': reason ?? '',
      'create_time': DateTime.now().toIso8601String(),
    };
    if (scoreItemId != null) map['score_item_id'] = scoreItemId;
    if (customName != null && customName.isNotEmpty) {
      map['custom_name'] = customName;
    }
    await DatabaseHelper.instance.insertScoreRecord(map);
    await loadRecords();
  }

  /// 批量评分：为多个学生（target type = 'student'）一次性添加评分记录
  /// 返回成功插入的记录数
  Future<int> batchAddScoreRecords({
    required List<int> targetIds,
    required double score,
    String? reason,
    int? scoreItemId,
    String? customName,
  }) async {
    await BackupService.instance.createBackup();
    final now = DateTime.now().toIso8601String();
    final records = <Map<String, dynamic>>[];
    for (final targetId in targetIds) {
      final map = <String, dynamic>{
        'target_type': 'student',
        'target_id': targetId,
        'score': score,
        'reason': reason ?? '',
        'create_time': now,
      };
      if (scoreItemId != null) map['score_item_id'] = scoreItemId;
      if (customName != null && customName.isNotEmpty) {
        map['custom_name'] = customName;
      }
      records.add(map);
    }
    final count = await DatabaseHelper.instance.batchInsertScoreRecords(
      records,
    );
    await loadRecords();
    return count;
  }

  Future<void> deleteScoreRecord(int id) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.deleteScoreRecord(id);
    await loadRecords();
  }

  // Statistics
  Future<void> loadStatistics({int? groupId}) async {
    _groupTotalScores = await DatabaseHelper.instance.getGroupTotalScores();
    _studentTotalScores = await DatabaseHelper.instance.getStudentTotalScores(
      groupId: groupId,
    );
    _filterGroupId = groupId;
    notifyListeners();
  }
}
