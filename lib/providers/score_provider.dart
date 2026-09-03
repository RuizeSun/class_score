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

  // ---- 计分规则（全局设置） ----
  double _studentInitialScore = 0;
  double _groupInitialScore = 0;
  String _groupScoreMode = 'sum'; // 'sum' | 'group_init' | 'avg'

  // 允许分值范围：'only_add' | 'only_deduct' | 'unlimited' | 'custom'
  String _scoreRangeMode = 'unlimited';
  double _scoreRangeMin = 0;
  double _scoreRangeMax = 0;

  double get studentInitialScore => _studentInitialScore;
  double get groupInitialScore => _groupInitialScore;
  String get groupScoreMode => _groupScoreMode;
  String get scoreRangeMode => _scoreRangeMode;
  double get scoreRangeMin => _scoreRangeMin;
  double get scoreRangeMax => _scoreRangeMax;

  // 默认是否使用快速评分（默认为关）
  bool _defaultQuickScoring = false;
  bool get defaultQuickScoring => _defaultQuickScoring;

  // 当前加载记录时使用的筛选状态，用于 add/delete 后保持筛选
  String? _lastRecordTargetType;
  int? _lastRecordTargetId;
  int? _lastRecordGroupId;

  // 待处理的小组筛选（用于统计分析→点击小组→跳转记录页自动筛选）
  int? _pendingGroupFilter;
  int? get pendingGroupFilter => _pendingGroupFilter;
  void requestGroupFilter(int? groupId) {
    _pendingGroupFilter = groupId;
    notifyListeners();
  }

  void consumeGroupFilter() {
    _pendingGroupFilter = null;
    // 不调用 notifyListeners()，由调用方控制
  }

  // 高级查询 - 周期范围筛选
  int? _advancedStartPeriod;
  int? _advancedEndPeriod;
  int? _advancedGroupId;
  bool _advancedShowGroup = false;
  List<Map<String, dynamic>> _advancedResults = [];
  Map<String, String?>? _advancedTimeRange;

  int? get advancedStartPeriod => _advancedStartPeriod;
  int? get advancedEndPeriod => _advancedEndPeriod;
  int? get advancedGroupId => _advancedGroupId;
  bool get advancedShowGroup => _advancedShowGroup;
  List<Map<String, dynamic>> get advancedResults => _advancedResults;
  Map<String, String?>? get advancedTimeRange => _advancedTimeRange;

  void setAdvancedPeriodRange(int? start, int? end) {
    _advancedStartPeriod = start;
    _advancedEndPeriod = end;
  }

  void setAdvancedGroupId(int? groupId) {
    _advancedGroupId = groupId;
  }

  void setAdvancedShowGroup(bool showGroup) {
    _advancedShowGroup = showGroup;
  }

  /// 执行高级查询：获取指定周期范围内的排名
  Future<void> executeAdvancedQuery() async {
    if (_advancedStartPeriod == null || _advancedEndPeriod == null) {
      _advancedResults = [];
      _advancedTimeRange = null;
      notifyListeners();
      return;
    }

    if (_advancedShowGroup) {
      // 查询小组排名
      _advancedResults = await DatabaseHelper.instance
          .getGroupTotalScoresByPeriodRange(
            startPeriod: _advancedStartPeriod,
            endPeriod: _advancedEndPeriod,
          );
    } else {
      // 查询学生排名
      _advancedResults = await DatabaseHelper.instance
          .getStudentTotalScoresByPeriodRange(
            startPeriod: _advancedStartPeriod,
            endPeriod: _advancedEndPeriod,
            groupId: _advancedGroupId,
          );
    }

    // 获取时间范围
    _advancedTimeRange = await DatabaseHelper.instance
        .getScoreTimeRangeByPeriod(
          startPeriod: _advancedStartPeriod,
          endPeriod: _advancedEndPeriod,
        );

    notifyListeners();
  }

  /// 清除高级查询结果
  void clearAdvancedQuery() {
    _advancedStartPeriod = null;
    _advancedEndPeriod = null;
    _advancedGroupId = null;
    _advancedResults = [];
    _advancedTimeRange = null;
    notifyListeners();
  }

  // 初始化 - 加载当前周期设置
  Future<void> init() async {
    final periodStr = await DatabaseHelper.instance.getSetting(
      'current_period',
    );
    _currentPeriod = int.tryParse(periodStr ?? '1') ?? 1;
    _defaultQuickScoring =
        (await DatabaseHelper.instance.getSetting('default_quick_scoring')) ==
        'true';
    await loadScoreConfig();
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
    bool isQuick = false,
  }) async {
    await BackupService.instance.createBackup();
    final map = <String, dynamic>{
      'target_type': targetType,
      'target_id': targetId,
      'score': score,
      'reason': reason ?? '',
      'create_time': DateTime.now().toIso8601String(),
      'period': _currentPeriod, // 当前周期
      'is_quick': isQuick ? 1 : 0,
    };
    if (scoreItemId != null) map['score_item_id'] = scoreItemId;
    if (customName != null && customName.isNotEmpty) {
      map['custom_name'] = customName;
    }
    final id = await DatabaseHelper.instance.insertScoreRecord(map);
    await _logRecordCreate(id, map);
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
    bool isQuick = false,
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
        'is_quick': isQuick ? 1 : 0,
      };
      if (scoreItemId != null) map['score_item_id'] = scoreItemId;
      if (customName != null && customName.isNotEmpty) {
        map['custom_name'] = customName;
      }
      records.add(map);
    }
    final ids = await DatabaseHelper.instance.insertScoreRecordsReturningIds(
      records,
    );
    for (var i = 0; i < ids.length; i++) {
      await _logRecordCreate(ids[i], records[i]);
    }
    await loadRecords();
    return ids.length;
  }

  /// 补充/更新评分记录的变动原因
  Future<void> updateScoreRecordReason(int id, String reason) async {
    await BackupService.instance.createBackup();
    await _updateRecordFieldsWithLog(
      id: id,
      values: {'reason': reason},
      action: 'supplement',
    );
    await loadRecords();
  }

  /// 批量删除评分记录：移入回收站（保留 7 天，可恢复），并清理过期回收站。
  Future<void> deleteScoreRecords(List<int> ids) async {
    if (ids.isEmpty) return;
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.purgeExpiredArchives(
      now: DateTime.now(),
      retention: _archiveRetention,
    );
    await DatabaseHelper.instance.archiveScoreRecords(
      ids,
      DateTime.now().toIso8601String(),
    );
    await loadRecords();
  }

  /// 批量补充/修改变动原因。
  /// [scoreItemId] 非空时将该记录绑定到预设评分项；否则视为自定义（[customName] 可为空串）。
  /// 自定义且 [customName] 为空时仅写原因、不改变分值/来源标记。
  Future<void> batchUpdateRecordComplements({
    required List<int> ids,
    required String reason,
    int? scoreItemId,
    String? customName,
    double? presetScore,
    bool applyPresetScore = false,
  }) async {
    if (ids.isEmpty) return;
    await BackupService.instance.createBackup();
    for (final id in ids) {
      final values = <String, dynamic>{'reason': reason};
      if (scoreItemId != null) {
        // 绑定预设评分项：作为普通（非快速）记录，原因可另附文字说明
        values['score_item_id'] = scoreItemId;
        values['custom_name'] = '';
        values['is_quick'] = 0;
        if (applyPresetScore && presetScore != null) {
          values['score'] = presetScore;
        }
      } else {
        // 自定义：写入自定义名称（可为空串），清除已绑定的预设项，不改变分值
        values['custom_name'] = customName ?? '';
        values['score_item_id'] = null;
        if (customName != null && customName.isNotEmpty) {
          values['is_quick'] = 0;
        }
      }
      await _updateRecordFieldsWithLog(id: id, values: values, action: 'supplement');
    }
    await loadRecords();
  }

  /// 单条记录补充/修改变动原因（复用批量逻辑）
  Future<void> updateRecordComplement({
    required int id,
    required String reason,
    int? scoreItemId,
    String? customName,
    double? presetScore,
    bool applyPresetScore = false,
  }) async {
    await batchUpdateRecordComplements(
      ids: [id],
      reason: reason,
      scoreItemId: scoreItemId,
      customName: customName,
      presetScore: presetScore,
      applyPresetScore: applyPresetScore,
    );
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
    await deleteScoreRecords([id]);
  }

  // ---- 修改记录历史 / 编辑 / 回收站 ----

  /// 回收站保留时长：7 天。
  static const Duration _archiveRetention = Duration(days: 7);

  String _scoreLabel(double v) {
    if (v > 0) return '+${v.toStringAsFixed(1)}';
    if (v < 0) return v.toStringAsFixed(1);
    return '0.0';
  }

  /// 记录一条“新增”历史。
  Future<void> _logRecordCreate(
    int id,
    Map<String, dynamic> map,
  ) async {
    final score = (map['score'] as num).toDouble();
    await DatabaseHelper.instance.insertScoreRecordLog({
      'record_id': id,
      'action_type': 'create',
      'field': null,
      'old_value': null,
      'new_value': null,
      'content': '新增评分记录（分值 ${_scoreLabel(score)}）',
      'log_time': (map['create_time'] as String?) ??
          DateTime.now().toIso8601String(),
    });
  }

  /// 通用：更新单条评分记录字段，并在变更时写入修改历史。
  /// [action] 'supplement'=补充/修改变动原因；'update'=编辑记录。
  Future<void> _updateRecordFieldsWithLog({
    required int id,
    required Map<String, dynamic> values,
    required String action,
  }) async {
    final dbh = DatabaseHelper.instance;
    final before = await dbh.getScoreRecordRaw(id);
    if (before == null) return;

    final logTime = DateTime.now().toIso8601String();
    final changed = <String>[];
    Map<String, dynamic>? extra;

    if (values.containsKey('score')) {
      final o = (before['score'] as num).toDouble();
      final n = (values['score'] as num).toDouble();
      if (o != n) {
        changed.add('分值 ${_scoreLabel(o)} → ${_scoreLabel(n)}');
        extra = {
          'field': 'score',
          'old_value': _scoreLabel(o),
          'new_value': _scoreLabel(n),
        };
      }
    }
    if (values.containsKey('reason')) {
      final o = (before['reason'] as String? ?? '');
      final n = (values['reason'] as String? ?? '');
      if (o != n) {
        if (o.isEmpty && n.isNotEmpty) {
          changed.add('补充变动原因：$n');
        } else if (n.isEmpty) {
          changed.add('清空变动原因');
        } else {
          changed.add('修改变动原因：$n');
        }
      }
    }
    if (values.containsKey('score_item_id') ||
        values.containsKey('custom_name')) {
      final oItem = before['score_item_id'] as int?;
      final oCustom = (before['custom_name'] as String? ?? '');
      final nItem = values.containsKey('score_item_id')
          ? values['score_item_id'] as int?
          : oItem;
      final nCustom = values.containsKey('custom_name')
          ? (values['custom_name'] as String? ?? '')
          : oCustom;
      final oLabel = oItem != null
          ? '关联预设评分项'
          : (oCustom.isNotEmpty ? '自定义：$oCustom' : '');
      final nLabel = nItem != null
          ? '关联预设评分项'
          : (nCustom.isNotEmpty ? '自定义：$nCustom' : '');
      if (oLabel != nLabel) {
        if (oLabel.isEmpty) {
          changed.add('设置$nLabel');
        } else if (nLabel.isEmpty) {
          changed.add('清除$oLabel');
        } else {
          changed.add('$oLabel → $nLabel');
        }
      }
    }

    await dbh.updateScoreRecordFields(id, values);
    if (changed.isEmpty) return;
    await dbh.insertScoreRecordLog({
      'record_id': id,
      'action_type': action,
      'field': extra?['field'],
      'old_value': extra?['old_value'],
      'new_value': extra?['new_value'],
      'content': changed.join('；'),
      'log_time': logTime,
    });
  }

  /// 编辑单条评分记录：可修改分值、变动原因以及评分项关联（预设或自定义）。
  /// 分值允许范围校验由调用方负责，此处仅落库并写“修改”历史。
  Future<void> editScoreRecord({
    required int id,
    required double score,
    String reason = '',
    int? scoreItemId,
    String customName = '',
  }) async {
    await BackupService.instance.createBackup();
    final before = await DatabaseHelper.instance.getScoreRecordRaw(id);
    if (before == null) return;

    final values = <String, dynamic>{
      'score': score,
      'reason': reason,
    };
    if (scoreItemId != null) {
      values['score_item_id'] = scoreItemId;
      values['custom_name'] = '';
      values['is_quick'] = 0;
    } else {
      values['score_item_id'] = null;
      values['custom_name'] = customName;
      if (customName.isNotEmpty) values['is_quick'] = 0;
    }

    await _updateRecordFieldsWithLog(id: id, values: values, action: 'update');
    await loadRecords();
  }

  /// 读取某条评分记录的修改历史（最新在前）。
  Future<List<Map<String, dynamic>>> getRecordLogs(int recordId) {
    return DatabaseHelper.instance.getScoreRecordLogs(recordId);
  }

  /// 读取回收站记录。
  Future<List<Map<String, dynamic>>> fetchArchivedRecords() {
    return DatabaseHelper.instance.getArchivedRecords();
  }

  /// 恢复回收站记录到列表（其目标被删则无法恢复，返回 0）。
  Future<int> restoreRecordFromArchive(int archiveId) async {
    await BackupService.instance.createBackup();
    final restored =
        await DatabaseHelper.instance.restoreArchivedRecord(archiveId);
    if (restored > 0) {
      await loadRecords();
    }
    return restored;
  }

  /// 永久删除回收站记录。
  Future<int> permanentlyDeleteArchivedRecords(List<int> archiveIds) async {
    if (archiveIds.isEmpty) return 0;
    await BackupService.instance.createBackup();
    return DatabaseHelper.instance.permanentlyDeleteArchivedRecords(archiveIds);
  }

  /// 清理回收站中超过 7 天的记录。
  Future<int> purgeExpiredArchives() async {
    return DatabaseHelper.instance.purgeExpiredArchives(
      now: DateTime.now(),
      retention: _archiveRetention,
    );
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

  // ---- 计分规则配置 ----
  /// 从数据库加载计分规则全局设置
  Future<void> loadScoreConfig() async {
    final db = DatabaseHelper.instance;
    _studentInitialScore =
        double.tryParse((await db.getSetting('student_initial_score')) ?? '') ??
        0.0;
    _groupInitialScore =
        double.tryParse((await db.getSetting('group_initial_score')) ?? '') ??
        0.0;
    _groupScoreMode = await db.getSetting('group_score_mode') ?? 'sum';
    _defaultQuickScoring = (await db.getSetting('default_quick_scoring')) ==
        'true';
    _scoreRangeMode = await db.getSetting('score_range_mode') ?? 'unlimited';
    _scoreRangeMin =
        double.tryParse((await db.getSetting('score_range_min')) ?? '') ?? 0;
    _scoreRangeMax =
        double.tryParse((await db.getSetting('score_range_max')) ?? '') ?? 0;
    notifyListeners();
  }

  /// 设置是否默认使用快速评分（持久化到设置）
  Future<void> setDefaultQuickScoring(bool value) async {
    await DatabaseHelper.instance.setSetting(
      'default_quick_scoring',
      value.toString(),
    );
    _defaultQuickScoring = value;
    notifyListeners();
  }

  /// 设置学生初始分（统一值）
  Future<void> setStudentInitialScore(double value) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.setSetting(
      'student_initial_score',
      value.toString(),
    );
    _studentInitialScore = value;
    notifyListeners();
  }

  /// 设置小组初始分（统一值）
  Future<void> setGroupInitialScore(double value) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.setSetting(
      'group_initial_score',
      value.toString(),
    );
    _groupInitialScore = value;
    notifyListeners();
  }

  /// 设置小组总分计算方式：'sum' | 'group_init' | 'avg'
  Future<void> setGroupScoreMode(String mode) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.setSetting('group_score_mode', mode);
    _groupScoreMode = mode;
    notifyListeners();
  }

  /// 设置允许分值范围模式：'only_add' | 'only_deduct' | 'unlimited' | 'custom'
  Future<void> setScoreRangeMode(String mode) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.setSetting('score_range_mode', mode);
    _scoreRangeMode = mode;
    notifyListeners();
  }

  /// 设置自定义允许分值范围：n1 <= 分值 <= n2
  Future<void> setScoreRange(double min, double max) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.setSetting('score_range_min', min.toString());
    await DatabaseHelper.instance.setSetting('score_range_max', max.toString());
    _scoreRangeMin = min;
    _scoreRangeMax = max;
    notifyListeners();
  }

  /// 根据允许分值范围规则判断某个分值是否允许使用。
  bool isScoreAllowed(double score) {
    switch (_scoreRangeMode) {
      case 'only_add':
        return score >= 0;
      case 'only_deduct':
        return score <= 0;
      case 'custom':
        return score >= _scoreRangeMin && score <= _scoreRangeMax;
      case 'unlimited':
      default:
        return true;
    }
  }
}
