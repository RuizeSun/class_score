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

  // 当前评分周期
  int _currentPeriod = 1;
  int get currentPeriod => _currentPeriod;

  // 当前加载记录时使用的筛选状态，用于 add/delete 后保持筛选
  String? _lastRecordTargetType;
  int? _lastRecordTargetId;
  int? _lastRecordGroupId;

  // 初始化 - 加载当前周期设置
  Future<void> init() async {
    final periodStr = await DatabaseHelper.instance.getSetting(
      'current_period',
    );
    _currentPeriod = int.tryParse(periodStr ?? '1') ?? 1;
    notifyListeners();
  }

  /// 加载评分记录。支持按 targetType + targetId 筛选，也支持按 groupId 筛选（查小组内所有成员记录）。
  /// 如果不传任何参数，则使用上次 loadRecords 的筛选条件重新加载。
  Future<void> loadRecords({
    String? targetType,
    int? targetId,
    int? groupId,
    bool resetFilters = false,
  }) async {
    if (resetFilters) {
      _lastRecordTargetType = null;
      _lastRecordTargetId = null;
      _lastRecordGroupId = null;
    }

    // 如果传入了筛选条件中的任意一个，更新保存的状态
    final hasNewFilter =
        targetType != null || targetId != null || groupId != null;
    if (hasNewFilter) {
      _lastRecordTargetType = targetType;
      _lastRecordTargetId = targetId;
      _lastRecordGroupId = groupId;
    }

    // 使用保存的筛选条件（参数优先，回退到保存值）
    final effectiveTargetType = hasNewFilter
        ? targetType
        : _lastRecordTargetType;
    final effectiveTargetId = hasNewFilter ? targetId : _lastRecordTargetId;
    final effectiveGroupId = hasNewFilter ? groupId : _lastRecordGroupId;

    List<Map<String, dynamic>> maps;
    if (effectiveGroupId != null) {
      maps = await DatabaseHelper.instance.getScoreRecordsAdvanced(
        targetType: 'group',
        targetId: effectiveGroupId,
        period: _currentPeriod,
      );
    } else {
      maps = await DatabaseHelper.instance.getScoreRecords(
        targetType: effectiveTargetType,
        targetId: effectiveTargetId,
        period: _currentPeriod,
      );
    }
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
      'period': _currentPeriod, // 当前周期
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
        'period': _currentPeriod, // 添加当前周期
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

  /// 切换到下一个评分周期
  /// 会清空新周期的所有评分记录
  Future<void> switchToNextPeriod() async {
    await BackupService.instance.createBackup();

    // 获取新周期号
    final nextPeriod = _currentPeriod + 1;

    // 删除新周期的所有评分记录（如果存在）
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'score_records',
      where: 'period = ?',
      whereArgs: [nextPeriod],
    );

    // 更新当前周期设置
    await DatabaseHelper.instance.setSetting(
      'current_period',
      nextPeriod.toString(),
    );

    // 更新内存中的值
    _currentPeriod = nextPeriod;
    notifyListeners();

    // 重新加载评分记录
    await loadRecords();
  }

  /// 切换到上一个评分周期
  Future<void> switchToPreviousPeriod() async {
    if (_currentPeriod <= 1) return;

    await BackupService.instance.createBackup();

    // 获取上一周期号
    final prevPeriod = _currentPeriod - 1;

    // 更新当前周期设置
    await DatabaseHelper.instance.setSetting(
      'current_period',
      prevPeriod.toString(),
    );

    // 更新内存中的值
    _currentPeriod = prevPeriod;
    notifyListeners();

    // 重新加载评分记录
    await loadRecords();
  }

  Future<void> deleteScoreRecord(int id) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.deleteScoreRecord(id);
    await loadRecords();
  }

  // Statistics
  Future<void> loadStatistics({int? groupId}) async {
    final rawGroupScores = await DatabaseHelper.instance.getGroupTotalScores(
      period: _currentPeriod,
    );
    // 获取每个小组的成员数量，过滤掉"未分组"且没有成员的组
    final allStudents = await DatabaseHelper.instance.getStudents();
    final groupMemberCount = <int, int>{};
    for (final s in allStudents) {
      final gid = s['group_id'] as int;
      groupMemberCount[gid] = (groupMemberCount[gid] ?? 0) + 1;
    }
    _groupTotalScores = rawGroupScores.where((g) {
      final name = g['name'] as String;
      final id = g['id'] as int;
      if (name == '未分组') {
        return (groupMemberCount[id] ?? 0) > 0;
      }
      return true;
    }).toList();
    _studentTotalScores = await DatabaseHelper.instance.getStudentTotalScores(
      groupId: groupId,
      period: _currentPeriod,
    );
    _filterGroupId = groupId;
    notifyListeners();
  }
}
