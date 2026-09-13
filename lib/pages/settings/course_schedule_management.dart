import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/schedule_import_service.dart';
import 'settings_common.dart';

/// Show dialog to add or edit a course schedule.
///
/// A [schedule] map without an 'id' is treated as a pre-filled new course
/// (used when tapping an empty cell in the grid view).
void showCourseScheduleDialog(
  BuildContext context, {
  Map<String, dynamic>? schedule,
}) {
  final bool isEditing = schedule != null && schedule['id'] != null;
  int selectedWeekday = schedule?['weekday'] as int? ?? 1;
  String? errorText;
  final nameController = TextEditingController(
    text: schedule?['course_name'] as String? ?? '',
  );
  final startController = TextEditingController(
    text: schedule?['start_time'] as String? ?? '',
  );
  final endController = TextEditingController(
    text: schedule?['end_time'] as String? ?? '',
  );

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: Text(isEditing ? '编辑课程' : '添加课程'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<int>(
              initialValue: selectedWeekday,
              decoration: const InputDecoration(
                labelText: '星期',
                border: OutlineInputBorder(),
              ),
              items: [1, 2, 3, 4, 5, 6, 7]
                  .map(
                    (d) => DropdownMenuItem(
                      value: d,
                      child: Text(AuthProvider.weekdayNames[d] ?? '周$d'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setDialogState(() => selectedWeekday = v!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '课程名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: startController,
                    decoration: const InputDecoration(
                      labelText: '开始时间',
                      border: OutlineInputBorder(),
                      hintText: '08:00',
                    ),
                    keyboardType: TextInputType.datetime,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: endController,
                    decoration: const InputDecoration(
                      labelText: '结束时间',
                      border: OutlineInputBorder(),
                      hintText: '09:40',
                    ),
                    keyboardType: TextInputType.datetime,
                  ),
                ),
              ],
            ),
            if (errorText != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.error_outline, size: 18, color: Colors.red),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      errorText!,
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final name = nameController.text.trim();
              final start = ScheduleImportService.parseScheduleTime(
                startController.text,
              );
              final end = ScheduleImportService.parseScheduleTime(
                endController.text,
              );

              if (name.isEmpty) {
                setDialogState(() => errorText = '请输入课程名称');
                return;
              }
              if (start == null) {
                setDialogState(() => errorText = '开始时间格式不正确，例如 08:00');
                return;
              }
              if (end == null) {
                setDialogState(() => errorText = '结束时间格式不正确，例如 09:40');
                return;
              }
              if (end.compareTo(start) <= 0) {
                setDialogState(() => errorText = '结束时间需晚于开始时间');
                return;
              }

              final map = {
                'weekday': selectedWeekday,
                'course_name': name,
                'start_time': start,
                'end_time': end,
              };
              if (isEditing) {
                context.read<AuthProvider>().updateCourseSchedule(
                  schedule['id'] as int,
                  map,
                );
              } else {
                context.read<AuthProvider>().addCourseSchedule(map);
              }
              Navigator.pop(ctx);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

/// 课程表展示模式
enum CourseScheduleViewMode { grid, table }

/// 可嵌入 SettingsHubPage 的课程表管理视图（不包含 Scaffold/AppBar）。
///
/// - 网格视图：按星期 × 时间节次展示，点击单元格快速添加/编辑
/// - 表格视图：行内直接编辑，显式"保存"后统一写库
/// - 导入：从 CSV / Excel 批量导入课程表
class CourseScheduleManagementView extends StatefulWidget {
  const CourseScheduleManagementView({
    super.key,
    required this.onShowCourseDialog,
  });

  final void Function({Map<String, dynamic>? schedule}) onShowCourseDialog;

  @override
  State<CourseScheduleManagementView> createState() =>
      _CourseScheduleManagementViewState();
}

class _CourseScheduleManagementViewState
    extends State<CourseScheduleManagementView> {
  CourseScheduleViewMode _mode = CourseScheduleViewMode.grid;
  final List<_EditableScheduleRow> _rows = [];
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadRowsFromProvider();
    });
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  // ---- 表格编辑状态 ----

  void _loadRowsFromProvider() {
    final schedules = context.read<AuthProvider>().courseSchedules;
    for (final row in _rows) {
      row.dispose();
    }
    _rows
      ..clear()
      ..addAll(schedules.map(_EditableScheduleRow.fromMap));
    for (final row in _rows) {
      _attachDirtyListeners(row);
    }
    if (mounted) {
      setState(() => _dirty = false);
    }
  }

  void _attachDirtyListeners(_EditableScheduleRow row) {
    void mark() => _markDirty();
    row.nameController.addListener(mark);
    row.startController.addListener(mark);
    row.endController.addListener(mark);
  }

  void _markDirty() {
    if (_dirty || !mounted) return;
    setState(() => _dirty = true);
  }

  void _switchMode(CourseScheduleViewMode mode) {
    if (mode == _mode) return;
    if (mode == CourseScheduleViewMode.table && !_dirty) {
      _loadRowsFromProvider();
    }
    setState(() => _mode = mode);
  }

  void _addRow() {
    final row = _EditableScheduleRow.empty();
    _attachDirtyListeners(row);
    setState(() {
      _rows.add(row);
      _dirty = true;
    });
  }

  void _removeRow(int index) {
    setState(() {
      _rows.removeAt(index).dispose();
      _dirty = true;
    });
  }

  Future<void> _discardChanges() async {
    final confirmed = await _confirm(
      title: '放弃未保存的修改？',
      content: '表格中的修改将全部丢失，恢复到当前已保存的课程表。',
      confirmText: '放弃修改',
      destructive: true,
    );
    if (confirmed != true) return;
    _loadRowsFromProvider();
  }

  Future<void> _saveRows() async {
    final maps = <Map<String, dynamic>>[];

    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      final name = row.nameController.text.trim();
      final startRaw = row.startController.text.trim();
      final endRaw = row.endController.text.trim();

      // 整行空白则忽略
      if (name.isEmpty && startRaw.isEmpty && endRaw.isEmpty) continue;

      if (name.isEmpty) {
        _showMessage('第 ${i + 1} 行：课程名称不能为空', isError: true);
        return;
      }
      final start = ScheduleImportService.parseScheduleTime(startRaw);
      if (start == null) {
        _showMessage('第 ${i + 1} 行：开始时间格式不正确（如 08:00）', isError: true);
        return;
      }
      final end = ScheduleImportService.parseScheduleTime(endRaw);
      if (end == null) {
        _showMessage('第 ${i + 1} 行：结束时间格式不正确（如 09:40）', isError: true);
        return;
      }
      if (end.compareTo(start) <= 0) {
        _showMessage('第 ${i + 1} 行：结束时间需晚于开始时间', isError: true);
        return;
      }

      maps.add({
        'weekday': row.weekday,
        'course_name': name,
        'start_time': start,
        'end_time': end,
      });
    }

    await context.read<AuthProvider>().replaceCourseSchedules(maps);
    if (!mounted) return;
    _loadRowsFromProvider();
    _showMessage('已保存 ${maps.length} 条课程安排');
  }

  // ---- 导入 ----

  Future<void> _importSchedules() async {
    final errorLogs = <String>[];
    final imported = await ScheduleImportService.pickAndImport(
      errorLogs: errorLogs,
    );
    if (imported == null || !mounted) return; // 用户取消

    if (imported.isEmpty) {
      if (errorLogs.isNotEmpty) {
        await _showErrorsDialog(errorLogs);
      }
      if (!mounted) return;
      _showMessage('文件中未找到有效的课程数据', isError: true);
      return;
    }

    final choice = await _showImportPreview(imported, errorLogs);
    if (choice == null || choice == 0 || !mounted) return;

    final overwrite = choice == -1;
    final count = await context.read<AuthProvider>().importCourseSchedules(
      imported.map((e) => e.toMap()).toList(),
      overwrite: overwrite,
    );
    if (!mounted) return;

    _loadRowsFromProvider();
    _showMessage(overwrite ? '已覆盖导入 $count 条课程安排' : '已追加导入 $count 条课程安排');
  }

  Future<int?> _showImportPreview(
    List<ImportedSchedule> imported,
    List<String> errorLogs,
  ) {
    bool overwrite = false;
    return showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('导入课程表预览'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('共找到 ${imported.length} 条课程安排'),
                if (errorLogs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${errorLogs.length} 条记录被跳过',
                      style: TextStyle(color: Colors.orange.shade800),
                    ),
                  ),
                const SizedBox(height: 12),
                const Text(
                  '预览（前 10 条）：',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 220,
                  child: ListView(
                    children: imported
                        .take(10)
                        .map(
                          (s) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              '${AuthProvider.weekdayNames[s.weekday] ?? '周${s.weekday}'}  '
                              '${s.startTime}-${s.endTime}  ${s.courseName}',
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                if (imported.length > 10)
                  Text('... 还有 ${imported.length - 10} 条'),
                if (errorLogs.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => _showErrorsDialog(errorLogs),
                    icon: const Icon(Icons.error_outline, size: 18),
                    label: Text('查看跳过的 ${errorLogs.length} 条记录'),
                  ),
                ],
                CheckboxListTile(
                  title: const Text('覆盖导入（清空现有课程表后导入）'),
                  subtitle: const Text(
                    '警告：将删除当前所有课程安排',
                    style: TextStyle(color: Colors.red),
                  ),
                  value: overwrite,
                  onChanged: (v) =>
                      setDialogState(() => overwrite = v ?? false),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 0),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, overwrite ? -1 : 1),
              child: Text(overwrite ? '确认覆盖导入' : '确认追加导入'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showErrorsDialog(List<String> errors) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('跳过的记录（${errors.length}）'),
        content: SizedBox(
          width: 480,
          height: 320,
          child: ListView(
            children: errors
                .map(
                  (e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(e, style: const TextStyle(fontSize: 13)),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildToolbar(context),
        if (_mode == CourseScheduleViewMode.table && _dirty)
          _buildDirtyBanner(context),
        Expanded(
          child: _mode == CourseScheduleViewMode.grid
              ? _buildGridView(context)
              : _buildTableView(context),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return SettingsToolbar(
      children: [
        SegmentedButton<CourseScheduleViewMode>(
          segments: const [
            ButtonSegment(
              value: CourseScheduleViewMode.grid,
              icon: Icon(Icons.grid_on),
              label: Text('网格'),
            ),
            ButtonSegment(
              value: CourseScheduleViewMode.table,
              icon: Icon(Icons.table_rows),
              label: Text('表格'),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (selection) => _switchMode(selection.first),
          showSelectedIcon: false,
        ),
        OutlinedButton.icon(
          onPressed: _importSchedules,
          icon: const Icon(Icons.file_upload_outlined),
          label: const Text('导入'),
        ),
        FilledButton.tonalIcon(
          onPressed: () => widget.onShowCourseDialog(),
          icon: const Icon(Icons.add),
          label: const Text('添加课程'),
        ),
        if (_mode == CourseScheduleViewMode.table && _dirty) ...[
          FilledButton.icon(
            onPressed: _saveRows,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存'),
          ),
          TextButton(onPressed: _discardChanges, child: const Text('取消')),
        ],
      ],
    );
  }

  Widget _buildDirtyBanner(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.edit_note, size: 18, color: Colors.amber.shade900),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '表格中有未保存的修改，点击"保存"写入课程表',
              style: TextStyle(color: Colors.amber.shade900, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 网格视图 ----

  Widget _buildGridView(BuildContext context) {
    final schedules = context.watch<AuthProvider>().courseSchedules;
    if (schedules.isEmpty) {
      return _buildEmptyState(
        icon: Icons.calendar_month,
        message: '暂无课程安排',
        hint: '点击"添加课程"或直接导入课程表',
      );
    }

    // 时间节次（按开始时间去重排序）
    final slotEnds = <String, String>{};
    for (final s in schedules) {
      slotEnds.putIfAbsent(
        s['start_time'] as String,
        () => s['end_time'] as String,
      );
    }
    final slots = slotEnds.keys.toList()..sort();

    // 单元格内容：weekday|start_time -> 课程列表
    final cells = <String, List<Map<String, dynamic>>>{};
    for (final s in schedules) {
      cells
          .putIfAbsent(
            '${s['weekday']}|${s['start_time']}',
            () => <Map<String, dynamic>>[],
          )
          .add(s);
    }

    final theme = Theme.of(context);

    // 表格宽度自适应可用空间：时间列固定，星期列等分，避免横向滚动
    return Scrollbar(
      child: SingleChildScrollView(
        padding: EdgeInsets.zero,
        child: Table(
          border: TableBorder.all(color: theme.dividerColor, width: 0.5),
          columnWidths: {
            0: const FixedColumnWidth(88),
            for (int d = 1; d <= 7; d++) d: const FlexColumnWidth(),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              children: [
                _gridHeaderCell(context, '时间'),
                for (int d = 1; d <= 7; d++)
                  _gridHeaderCell(
                    context,
                    AuthProvider.weekdayNames[d] ?? '周$d',
                  ),
              ],
            ),
            for (final slot in slots)
              TableRow(
                children: [
                  _gridTimeCell(context, slot, slotEnds[slot]!),
                  for (int d = 1; d <= 7; d++)
                    _gridCourseCell(
                      context,
                      d,
                      slot,
                      slotEnds[slot]!,
                      cells['$d|$slot'] ?? const [],
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _gridHeaderCell(BuildContext context, String text) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _gridTimeCell(BuildContext context, String start, String end) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: Column(
        children: [
          Text(start, style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(
            end,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _gridCourseCell(
    BuildContext context,
    int weekday,
    String start,
    String end,
    List<Map<String, dynamic>> items,
  ) {
    return InkWell(
      onTap: () => widget.onShowCourseDialog(
        schedule: {'weekday': weekday, 'start_time': start, 'end_time': end},
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.all(6),
        child: items.isEmpty
            ? Center(
                child: Icon(Icons.add, size: 18, color: Colors.grey.shade400),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: items.map((s) => _courseChip(context, s)).toList(),
              ),
      ),
    );
  }

  Widget _courseChip(BuildContext context, Map<String, dynamic> schedule) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => widget.onShowCourseDialog(schedule: schedule),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  schedule['course_name'] as String,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onPrimaryContainer,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          InkWell(
            onTap: () => _confirmDeleteSchedule(schedule),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Icon(
                Icons.close,
                size: 14,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteSchedule(Map<String, dynamic> schedule) async {
    final confirmed = await _confirm(
      title: '确认删除',
      content: '确定删除课程"${schedule['course_name']}"吗？',
      confirmText: '删除',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    await context.read<AuthProvider>().deleteCourseSchedule(
      schedule['id'] as int,
    );
  }

  // ---- 表格视图（行内直接编辑）----

  Widget _buildTableView(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Expanded(
          child: _rows.isEmpty
              ? _buildEmptyState(
                  icon: Icons.table_rows,
                  message: '暂无课程',
                  hint: '点击下方"添加一行"开始录入',
                )
              : Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Table(
                      border: TableBorder(
                        horizontalInside: BorderSide(
                          color: theme.dividerColor,
                          width: 0.5,
                        ),
                      ),
                      columnWidths: const {
                        0: FixedColumnWidth(104),
                        1: FlexColumnWidth(3),
                        2: FixedColumnWidth(112),
                        3: FixedColumnWidth(112),
                        4: FixedColumnWidth(52),
                      },
                      defaultVerticalAlignment:
                          TableCellVerticalAlignment.middle,
                      children: [
                        _buildTableHeaderRow(context),
                        for (int i = 0; i < _rows.length; i++)
                          _buildEditableRow(context, i),
                      ],
                    ),
                  ),
                ),
        ),
        const Divider(height: 1),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: TextButton.icon(
              onPressed: _addRow,
              icon: const Icon(Icons.add),
              label: const Text('添加一行'),
            ),
          ),
        ),
      ],
    );
  }

  TableRow _buildTableHeaderRow(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget cell(String text) => Container(
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
    );

    return TableRow(
      children: [
        cell('星期'),
        cell('课程名称'),
        cell('开始时间'),
        cell('结束时间'),
        cell(''),
      ],
    );
  }

  TableRow _buildEditableRow(BuildContext context, int index) {
    final row = _rows[index];
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: row.weekday,
              isExpanded: true,
              isDense: true,
              items: [1, 2, 3, 4, 5, 6, 7]
                  .map(
                    (d) => DropdownMenuItem(
                      value: d,
                      child: Text(AuthProvider.weekdayNames[d] ?? '周$d'),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  row.weekday = v;
                  _dirty = true;
                });
              },
            ),
          ),
        ),
        _buildTableCell(
          child: _buildTableTextField(
            controller: row.nameController,
            hint: '课程名称',
          ),
        ),
        _buildTableCell(
          child: _buildTableTimeField(controller: row.startController),
        ),
        _buildTableCell(
          child: _buildTableTimeField(controller: row.endController),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: IconButton(
            tooltip: '删除此行',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _removeRow(index),
          ),
        ),
      ],
    );
  }

  Widget _buildTableCell({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: child,
    );
  }

  Widget _buildTableTextField({
    required TextEditingController controller,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
      ),
    );
  }

  Widget _buildTableTimeField({required TextEditingController controller}) {
    return Focus(
      onFocusChange: (hasFocus) {
        if (hasFocus) return;
        // 失焦时自动归一化时间格式
        final normalized = ScheduleImportService.parseScheduleTime(
          controller.text,
        );
        if (normalized != null && normalized != controller.text) {
          controller.text = normalized;
        }
      },
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.datetime,
        decoration: const InputDecoration(
          hintText: 'HH:mm',
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
      ),
    );
  }

  // ---- 通用辅助 ----

  Widget _buildEmptyState({
    required IconData icon,
    required String message,
    required String hint,
  }) {
    return SettingsEmptyState(icon: icon, message: message, hint: hint);
  }

  Future<bool?> _confirm({
    required String title,
    required String content,
    required String confirmText,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              confirmText,
              style: destructive ? const TextStyle(color: Colors.red) : null,
            ),
          ),
        ],
      ),
    );
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Colors.red : Colors.green,
        ),
      );
  }
}

/// 表格视图中的一行（持有自己的输入控制器）
class _EditableScheduleRow {
  int weekday;
  final TextEditingController nameController;
  final TextEditingController startController;
  final TextEditingController endController;

  _EditableScheduleRow({
    required this.weekday,
    required String name,
    required String start,
    required String end,
  }) : nameController = TextEditingController(text: name),
       startController = TextEditingController(text: start),
       endController = TextEditingController(text: end);

  factory _EditableScheduleRow.fromMap(Map<String, dynamic> map) {
    return _EditableScheduleRow(
      weekday: map['weekday'] as int,
      name: map['course_name'] as String,
      start: map['start_time'] as String,
      end: map['end_time'] as String,
    );
  }

  factory _EditableScheduleRow.empty() {
    return _EditableScheduleRow(weekday: 1, name: '', start: '', end: '');
  }

  void dispose() {
    nameController.dispose();
    startController.dispose();
    endController.dispose();
  }
}
