import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/score_item_provider.dart';
import '../providers/score_provider.dart';
import 'student_name_text.dart';

/// 评分记录条目（列表样式 + 操作逻辑的唯一实现）。
///
/// 「记录管理」与「图表分析」共用此组件，避免重复实现条目样式。
/// [record] 需为 `score_records.*` 关联查询结果，包含：
/// `target_name` / `target_student_number` / `target_include_in_group_total` /
/// `score_item_name`。
class ScoreRecordTile extends StatelessWidget {
  /// 记录数据
  final Map<String, dynamic> record;

  /// 批量选择模式：显示勾选框，点击整行切换选中状态
  final bool batchMode;

  /// 当前是否被选中（仅批量模式生效）
  final bool selected;

  /// 批量模式下切换选中状态
  final VoidCallback? onToggleSelect;

  /// 是否已解锁：解锁后才显示编辑/查看修改记录/删除按钮
  final bool isUnlocked;

  /// 自定义「编辑记录」行为；为空时使用内置标准流程
  final VoidCallback? onEdit;

  /// 自定义「查看修改记录」行为；为空时使用内置标准流程
  final VoidCallback? onShowHistory;

  /// 自定义「删除」行为；为空时使用内置标准流程
  final VoidCallback? onDelete;

  /// 记录被修改/删除成功后回调，供页面刷新自身数据
  final VoidCallback? onMutated;

  const ScoreRecordTile({
    super.key,
    required this.record,
    this.batchMode = false,
    this.selected = false,
    this.onToggleSelect,
    this.isUnlocked = false,
    this.onEdit,
    this.onShowHistory,
    this.onDelete,
    this.onMutated,
  });

  Future<void> _handleEdit(BuildContext context) async {
    if (onEdit != null) {
      onEdit!();
      return;
    }
    final changed = await RecordActions.editRecord(context, record);
    if (changed) onMutated?.call();
  }

  Future<void> _handleShowHistory(BuildContext context) async {
    if (onShowHistory != null) {
      onShowHistory!();
      return;
    }
    await RecordActions.showHistory(context, record);
  }

  Future<void> _handleDelete(BuildContext context) async {
    if (onDelete != null) {
      onDelete!();
      return;
    }
    final deleted = await RecordActions.deleteRecords(context, [record]);
    if (deleted) onMutated?.call();
  }

  /// 窄栏阈值：低于该宽度时把「编辑 / 查看修改记录 / 删除」收进溢出菜单，
  /// 保证「姓名#学号」与分数不被操作按钮挤掉（左右分栏的右栏常见情形）。
  static const double compactBreakpoint = 560;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => _buildTile(
        context,
        compact: constraints.maxWidth < compactBreakpoint,
      ),
    );
  }

  Widget _buildTile(BuildContext context, {required bool compact}) {
    final r = record;
    final score = (r['score'] as num).toDouble();
    final isPositive = score >= 0;
    final time = r['create_time'] as String? ?? '';
    // Format time display
    final displayTime = time.length >= 19
        ? time.replaceFirst('T', ' ').substring(0, 19)
        : time;

    final studentNumber = r['target_student_number'] as String? ?? '';
    // 姓名#学号（学号灰色）；小组记录的学号为空，只显示名称
    final titleSpan = StudentDisplay.span(
      name: r['target_name'] as String? ?? '(未知)',
      studentNumber: studentNumber,
    );

    // 该学生是否不参与小组总分统计
    final notInGroupTotal =
        r['target_type'] == 'student' &&
        ((r['target_include_in_group_total'] as int?) ?? 1) == 0;

    // 是否由快速评分产生
    final isQuick = (r['is_quick'] as num? ?? 0) != 0;

    // 构建原因/评分项文本
    final scoreItemName = r['score_item_name'] as String? ?? '';
    final customName = r['custom_name'] as String? ?? '';
    final reason = r['reason'] as String? ?? '';

    // 构建显示文本：同时显示评分项和变动原因
    String? displayReason;
    final hasScoreItem = scoreItemName.isNotEmpty || customName.isNotEmpty;
    final hasReason = reason.isNotEmpty;

    if (hasScoreItem && hasReason) {
      final itemText = scoreItemName.isNotEmpty ? scoreItemName : customName;
      displayReason = '$itemText · $reason';
    } else if (hasScoreItem) {
      displayReason = scoreItemName.isNotEmpty ? scoreItemName : customName;
    } else if (hasReason) {
      displayReason = reason;
    }

    // 快速评分记录：标识来源，未填写原因时提示
    if (isQuick) {
      displayReason = '快速评分 · '
          '${displayReason?.isNotEmpty == true ? displayReason : '未填写原因'}';
    }

    // 构建subtitle内容
    String subtitleContent;
    if (displayReason != null && displayReason.isNotEmpty) {
      subtitleContent = '$displayReason\n$displayTime';
    } else {
      subtitleContent = displayTime;
    }

    final showActions = !batchMode && isUnlocked;

    return ListTile(
      leading: batchMode
          ? Checkbox(
              value: selected,
              onChanged: (_) => onToggleSelect?.call(),
            )
          : null,
      selected: selected,
      tileColor: batchMode && selected
          ? Colors.blueGrey.withValues(alpha: 0.08)
          : null,
      onTap: batchMode ? () => onToggleSelect?.call() : null,
      title: Row(
        children: [
          Flexible(
            child: Text.rich(titleSpan, overflow: TextOverflow.ellipsis),
          ),
          if (notInGroupTotal) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '不参与小组总分',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        subtitleContent,
        maxLines: displayReason != null && displayReason.isNotEmpty ? 2 : 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            score.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: isPositive ? Colors.green : Colors.red,
            ),
          ),
          // 窄栏：操作收进溢出菜单，优先保证姓名与分数可读
          if (showActions && compact)
            PopupMenuButton<String>(
              tooltip: '更多操作',
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (value) => switch (value) {
                'history' => _handleShowHistory(context),
                'delete' => _handleDelete(context),
                _ => _handleEdit(context),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑记录')),
                PopupMenuItem(value: 'history', child: Text('查看修改记录')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          // 宽栏：维持行内按钮
          // 编辑记录（修改分值/变动原因/评分项关联；所有记录可用）
          if (showActions && !compact)
            IconButton(
              tooltip: '编辑记录',
              icon: const Icon(Icons.edit, size: 20),
              color: Colors.blueGrey,
              onPressed: () => _handleEdit(context),
            ),
          // 查看该记录的修改记录
          if (showActions && !compact)
            IconButton(
              tooltip: '查看修改记录',
              icon: const Icon(Icons.history, size: 20),
              color: Colors.blueGrey,
              onPressed: () => _handleShowHistory(context),
            ),
          // 单条删除（移入回收站；批量模式下交由批量删除处理）
          if (showActions && !compact)
            IconButton(
              icon: const Icon(Icons.delete, size: 20),
              onPressed: () => _handleDelete(context),
            ),
        ],
      ),
    );
  }
}


/// 评分记录的通用操作：编辑 / 查看修改记录 / 删除（移入回收站）。
///
/// 「记录管理」与「图表分析」共用，保证行为与文案一致。
class RecordActions {
  const RecordActions._();

  /// 编辑单条记录（分值/变动原因/评分项关联）。返回是否保存成功。
  static Future<bool> editRecord(
    BuildContext context,
    Map<String, dynamic> r,
  ) async {
    final scoreProvider = context.read<ScoreProvider>();
    final result = await showDialog<_EditRecordResult>(
      context: context,
      builder: (_) => _EditRecordDialog(
        currentScore: (r['score'] as num).toDouble(),
        currentReason: (r['reason'] as String? ?? ''),
        currentItemId: r['score_item_id'] as int?,
        currentCustom: (r['custom_name'] as String? ?? ''),
      ),
    );
    if (result == null || !context.mounted) return false;

    if (!scoreProvider.isScoreAllowed(result.score)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('分值不在允许范围内，无法保存')));
      return false;
    }
    await scoreProvider.editScoreRecord(
      id: r['id'] as int,
      score: result.score,
      reason: result.reason,
      scoreItemId: result.scoreItemId,
      customName: result.customName,
    );
    if (!context.mounted) return false;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('记录已修改'), duration: Duration(seconds: 2)));
    return true;
  }

  /// 查看某条记录的修改记录（新增/补充变动原因/修改/删除）。
  static Future<void> showHistory(
    BuildContext context,
    Map<String, dynamic> r,
  ) async {
    final provider = context.read<ScoreProvider>();
    final logs = await provider.getRecordLogs(r['id'] as int);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _RecordHistoryDialog(
        // 姓名#学号（学号灰色） + 「的修改记录」
        title: TextSpan(
          children: [
            StudentDisplay.span(
              name: r['target_name'] as String? ?? '(未知)',
              studentNumber: r['target_student_number'] as String? ?? '',
            ),
            const TextSpan(text: ' 的修改记录'),
          ],
        ),
        logs: logs,
      ),
    );
  }

  /// 批量删除确认并执行（单条删除同样适用）。返回是否删除成功。
  /// [onDeleted] 在删除成功后回调被删除的记录 id，供页面清理选中状态。
  static Future<bool> deleteRecords(
    BuildContext context,
    List<Map<String, dynamic>> targets, {
    ValueChanged<List<int>>? onDeleted,
  }) async {
    if (targets.isEmpty) return false;
    final ids = targets.map((r) => r['id'] as int).toList();
    final isSingle = targets.length == 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isSingle ? '确认删除' : '批量删除'),
        content: Text(
          isSingle
              ? '确定删除这条评分记录吗？此操作不可撤销。'
              : '确定删除选中的 ${targets.length} 条评分记录吗？此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;
    await context.read<ScoreProvider>().deleteScoreRecords(ids);
    if (!context.mounted) return false;
    onDeleted?.call(ids);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已删除 ${targets.length} 条评分记录'),
        duration: const Duration(seconds: 2),
      ),
    );
    return true;
  }
}


/// 编辑记录对话框的返回结果。
class _EditRecordResult {
  final double score;
  final int? scoreItemId; // null 表示自定义/不关联预设
  final String customName;
  final String reason;

  _EditRecordResult({
    required this.score,
    this.scoreItemId,
    this.customName = '',
    this.reason = '',
  });
}

/// 编辑单条评分记录（分值/变动原因/评分项关联）对话框。
class _EditRecordDialog extends StatefulWidget {
  final double currentScore;
  final String currentReason;
  final int? currentItemId;
  final String currentCustom;

  const _EditRecordDialog({
    required this.currentScore,
    required this.currentReason,
    this.currentItemId,
    this.currentCustom = '',
  });

  @override
  State<_EditRecordDialog> createState() => _EditRecordDialogState();
}

class _EditRecordDialogState extends State<_EditRecordDialog> {
  late final TextEditingController _scoreController;
  late final TextEditingController _reasonController;
  late final TextEditingController _customController;
  late int? _chosenItemId;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _scoreController = TextEditingController(
      text: widget.currentScore.toString(),
    );
    _reasonController = TextEditingController(text: widget.currentReason);
    _customController = TextEditingController(text: widget.currentCustom);
    _chosenItemId = widget.currentItemId;
  }

  @override
  void dispose() {
    _scoreController.dispose();
    _reasonController.dispose();
    _customController.dispose();
    super.dispose();
  }

  void _save() {
    final score = double.tryParse(_scoreController.text.trim());
    if (score == null) {
      setState(() => _error = '请输入有效的分值（可含负号与小数，如 0.5 或 -1）');
      return;
    }
    if (!context.read<ScoreProvider>().isScoreAllowed(score)) {
      setState(() => _error = '分值不在当前允许范围内，无法保存');
      return;
    }
    Navigator.pop(
      context,
      _EditRecordResult(
        score: score,
        scoreItemId: _chosenItemId,
        customName: _customController.text.trim(),
        reason: _reasonController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = context.read<ScoreItemProvider>().items;
    final isCustom = _chosenItemId == null;
    return AlertDialog(
      title: const Text('编辑记录'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _error,
                  style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                ),
              ),
            TextField(
              controller: _scoreController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(
                labelText: '分值',
                border: OutlineInputBorder(),
                hintText: '请输入分值（支持小数，如 0.5 或 -1）',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int?>(
              key: ValueKey('item_$_chosenItemId'),
              initialValue: _chosenItemId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '评分项',
                border: OutlineInputBorder(),
                hintText: '选择预设（自定义则不填）',
              ),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('自定义'),
                  ),
                ),
                ...items.map(
                  (item) => DropdownMenuItem<int?>(
                    value: item.id,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          (item.defaultScore > 0 ? '+' : '') +
                              item.defaultScore.toStringAsFixed(1),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => _chosenItemId = v),
            ),
            if (isCustom) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _customController,
                decoration: const InputDecoration(
                  labelText: '评分项名称（自定义）',
                  border: OutlineInputBorder(),
                  hintText: '如：考勤扣分、作业加分（不填则清除评分项）',
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _reasonController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '变动原因',
                border: OutlineInputBorder(),
                hintText: '请输入具体变动原因（可选）',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

/// 查看单条评分记录的修改记录对话框。
class _RecordHistoryDialog extends StatelessWidget {
  /// 标题（富文本：姓名#学号，学号为灰色）
  final InlineSpan title;
  final List<Map<String, dynamic>> logs;

  const _RecordHistoryDialog({required this.title, required this.logs});

  String _fmtTime(String iso) {
    if (iso.length < 19) return iso;
    return iso.replaceFirst('T', ' ').substring(0, 19);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text.rich(title),
      content: SizedBox(
        width: 460,
        height: 420,
        child: logs.isEmpty
            ? const Center(child: Text('暂无修改记录'))
            : ListView.builder(
                itemCount: logs.length,
                itemBuilder: (_, i) {
                  final log = logs[i];
                  final action = log['action_type'] as String? ?? 'update';
                  final content = log['content'] as String? ?? '';
                  final time = log['log_time'] as String? ?? '';
                  final (IconData icon, String label, Color color) =
                      switch (action) {
                        'create' => (
                          Icons.add_circle_outline,
                          '新增记录',
                          Colors.green.shade700,
                        ),
                        'supplement' => (
                          Icons.note_add_outlined,
                          '补充变动原因',
                          Colors.blue.shade700,
                        ),
                        'delete' => (
                          Icons.delete_outline,
                          '删除',
                          Colors.red.shade700,
                        ),
                        _ => (Icons.edit_outlined, '修改', Colors.orange.shade800),
                      };
                  final subtitle = content.isNotEmpty
                      ? '$content\n${_fmtTime(time)}'
                      : _fmtTime(time);
                  return ListTile(
                    leading: Icon(icon, color: color),
                    title: Text(
                      label,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: color,
                        fontSize: 13,
                      ),
                    ),
                    subtitle: Text(
                      subtitle,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    dense: true,
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

