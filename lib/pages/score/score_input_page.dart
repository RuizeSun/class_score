import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassSwitch;
import 'package:provider/provider.dart';
import '../../models/score_item.dart';
import '../../providers/group_provider.dart';
import '../../providers/student_provider.dart';
import '../../providers/score_provider.dart';
import '../../providers/score_item_provider.dart';
import '../../models/student.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/glass_buttons.dart';
import '../../widgets/glass_controls.dart';
import '../../widgets/glass_inputs.dart';
import '../../widgets/student_name_text.dart';
import 'ai_roster/ai_roster_capture_page.dart';

class ScoreInputPage extends StatefulWidget {
  const ScoreInputPage({super.key});

  @override
  State<ScoreInputPage> createState() => _ScoreInputPageState();
}

class _ScoreInputPageState extends State<ScoreInputPage> {
  final _scoreController = TextEditingController();
  final _reasonController = TextEditingController();
  final _customNameController = TextEditingController();

  int? _selectedGroupId; // 用于筛选学生
  int? _selectedItemId; // preset score item
  bool _loading = false;
  // 已选择的学生ID列表
  final Set<int> _selectedStudentIds = {};

  // 快速评分模式相关状态
  bool _quickMode = false;
  double _quickScore = 1;

  // 学生卡片统一宽度缓存。
  //
  // 卡片宽度取决于「所有学生里最长的姓名#学号」，原本在 build 里对每个学生
  // 跑一次 TextPainter.layout()——一次点选（每次点学生都会 setState）就要对
  // 全班几十人重新排版一遍文字。这是纯 CPU 工作，低配 i3 上点一下学生卡片
  // 就能吃掉几毫秒，手感是「点一下顿一下」。
  //
  // 这里按「学生名单 + 可用宽度」缓存测量结果：同一份名单下点选只读缓存。
  //
  // 命中判定用 [listEquals] 逐项比较，而不是 identical 比较列表对象：
  // 选了具体小组时 filteredStudents 走的是 `students.where(...).toList()`，
  // 每次 build 都会生成**新的 List 实例**，identical 永远为 false，缓存也就
  // 永远不命中。listEquals 比的是元素本身（Student 未重写 ==，等价于比对象
  // 身份），所以「成员完全没变」时能正确命中；一旦学生数据被重新加载（元素
  // 换成新对象）就自动失效，不会算出过期的宽度。
  double? _cachedCardWidth;
  List<Student>? _cachedCardWidthStudents;
  double? _cachedCardWidthAvailable;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GroupProvider>().loadGroups();
      context.read<StudentProvider>().loadStudents();
      context.read<ScoreItemProvider>().loadItems();
      context.read<ScoreProvider>().loadRecords(targetType: 'student');
      // 加载计分规则（含允许分值范围），并据此初始化快速评分状态
      context.read<ScoreProvider>().loadScoreConfig().then((_) {
        if (!mounted) return;
        setState(() {
          _quickMode = context.read<ScoreProvider>().defaultQuickScoring;
          _quickScore = _clampQuickScore(_quickScore);
        });
      });
    });
  }

  /// 计算学生卡片的统一宽度（按名单 + 可用宽度缓存）。
  ///
  /// 卡片宽度 = 图标(16) + 间距(6) + 最长「姓名#学号」文本宽度 + 水平内边距(16)，
  /// 并限制不超过可用宽度的 45%（保留 [Wrap] 的 spacing 余量）。
  ///
  /// 测量用的是与卡片渲染完全相同的 [StudentDisplay.span]，保证两者一致；
  /// 只是把结果缓存起来——同一份名单下反复点选学生都命中缓存。
  double _resolveCardWidth(List<Student> students, double availableWidth) {
    final cached = _cachedCardWidthStudents;
    if (_cachedCardWidth != null &&
        cached != null &&
        _cachedCardWidthAvailable == availableWidth &&
        listEquals(cached, students)) {
      return _cachedCardWidth!;
    }

    const textStyle = TextStyle(fontSize: 12);
    double maxCardWidth = 0;
    for (final s in students) {
      final textPainter = TextPainter(
        text: StudentDisplay.span(
          name: s.name,
          studentNumber: s.studentNumber,
          nameStyle: textStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      // 卡片内容宽度 = 图标(16) + 间距(6) + 文本宽度 + 水平内边距(16)
      final cardWidth = 16.0 + 6.0 + textPainter.width + 16.0;
      if (cardWidth > maxCardWidth) maxCardWidth = cardWidth;
    }

    final maxAllowedWidth = (availableWidth - 8.0) * 0.45;
    if (maxCardWidth > maxAllowedWidth) maxCardWidth = maxAllowedWidth;

    _cachedCardWidth = maxCardWidth;
    _cachedCardWidthStudents = students;
    _cachedCardWidthAvailable = availableWidth;
    return maxCardWidth;
  }

  Future<void> _switchToNextPeriod() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换到下一周期'),
        content: const Text(
          '即将切换到下一评分周期，当前周期的评分记录将保留，但下一周期的评分记录将被清空。\n\n确认切换吗？',
        ),
        actions: [
          GlassActionButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          GlassActionButton(
            onPressed: () => Navigator.pop(ctx, true),
            variant: GlassActionVariant.prominent,
            child: const Text('确认切换'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await context.read<ScoreProvider>().switchToNextPeriod();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已切换到下一评分周期'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  void dispose() {
    _scoreController.dispose();
    _reasonController.dispose();
    _customNameController.dispose();
    super.dispose();
  }

  void _onSelectPreset(ScoreItem? item) {
    if (item == null) {
      setState(() {
        _selectedItemId = null;
        _scoreController.clear();
        _customNameController.clear();
      });
    } else {
      setState(() {
        _selectedItemId = item.id;
        _scoreController.text = item.defaultScore.toString();
        _customNameController.clear();
      });
    }
  }

  void _toggleStudentSelection(int studentId) {
    setState(() {
      if (_selectedStudentIds.contains(studentId)) {
        _selectedStudentIds.remove(studentId);
      } else {
        _selectedStudentIds.add(studentId);
      }
    });
  }

  /// 打开 AI 选学生流程：取景/选图 → 裁剪 → 规则设置 → AI 推理 → 采用。
  Future<void> _openAiRoster() async {
    final students = context.read<StudentProvider>().students;
    final filtered = _selectedGroupId == null
        ? students
        : students.where((s) => s.groupId == _selectedGroupId).toList();
    if (filtered.isEmpty) {
      _showMsg('当前没有学生，请先添加学生');
      return;
    }
    final picked = await Navigator.push<Set<int>>(
      context,
      MaterialPageRoute(
        builder: (_) => AiRosterCapturePage(candidates: filtered),
      ),
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    setState(() {
      // 采用的学生可能不在当前小组筛选内，切回全部小组避免被筛选清掉
      _selectedGroupId = null;
      _selectedStudentIds.addAll(picked);
    });
    _showMsg('已通过 AI 选中 ${picked.length} 名学生');
  }

  void _selectAllStudents() {
    setState(() {
      final students = context.read<StudentProvider>().students;
      final filtered = _selectedGroupId == null
          ? students
          : students.where((s) => s.groupId == _selectedGroupId);
      final allSelected = filtered.every(
        (s) => _selectedStudentIds.contains(s.id),
      );
      if (allSelected) {
        _selectedStudentIds.clear();
      } else {
        for (final s in filtered) {
          _selectedStudentIds.add(s.id!);
        }
      }
    });
  }

  Future<void> _submit() async {
    // 快速评分模式下分值来自 _quickScore，否则从输入框解析
    final double score;
    if (_quickMode) {
      score = _clampQuickScore(_quickScore);
    } else {
      final scoreText = _scoreController.text.trim();
      if (scoreText.isEmpty) {
        _showMsg('请输入分值');
        return;
      }
      final parsed = double.tryParse(scoreText);
      if (parsed == null) {
        _showMsg('请输入有效的数值');
        return;
      }
      score = parsed;
    }

    // 校验分值是否符合允许分值范围规则
    if (!context.read<ScoreProvider>().isScoreAllowed(score)) {
      _showMsg('该分值不在允许的分值范围内，无法评分');
      return;
    }

    if (_selectedStudentIds.isEmpty) {
      _showMsg('请至少选择一名学生');
      return;
    }

    // 获取已选择的学生信息
    final students = context.read<StudentProvider>().students;
    final selectedStudents = students
        .where((s) => _selectedStudentIds.contains(s.id))
        .toList();

    // 确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认评分'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('即将为以下 ${selectedStudents.length} 名学生评分：'),
            const SizedBox(height: 8),
            ...selectedStudents.map(
              (s) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                // 姓名#学号（学号灰色）
                child: StudentNameText(
                  name: s.name,
                  studentNumber: s.studentNumber,
                ),
              ),
            ),
            const Divider(),
            Text('分值：$score'),
            Text(
              _quickMode
                  ? '来源：快速评分（原因可在记录管理中补充）'
                  : '原因：${_reasonController.text.trim().isEmpty ? '（无）' : _reasonController.text.trim()}',
            ),
          ],
        ),
        actions: [
          GlassActionButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          GlassActionButton(
            onPressed: () => Navigator.pop(ctx, true),
            variant: GlassActionVariant.prominent,
            child: const Text('确认提交'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _loading = true);
    final count = await context.read<ScoreProvider>().batchAddScoreRecords(
      targetIds: selectedStudents.map((s) => s.id!).toList(),
      score: score,
      reason: _quickMode ? '' : _reasonController.text.trim(),
      scoreItemId: _quickMode ? null : _selectedItemId,
      customName: _quickMode ? '' : _customNameController.text.trim(),
      isQuick: _quickMode,
    );
    setState(() => _loading = false);

    _scoreController.clear();
    _reasonController.clear();
    _customNameController.clear();
    setState(() {
      _selectedItemId = null;
      _selectedStudentIds.clear();
    });
    if (!context.mounted) return;
    _showMsg('评分完成，成功录入 $count 条记录');
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  void _setQuickMode(bool value) {
    setState(() {
      _quickMode = value;
      _selectedItemId = null;
      _quickScore = _clampQuickScore(_quickScore);
    });
  }

  void _setQuickScore(double value) {
    setState(() {
      _quickScore = _clampQuickScore(value);
    });
  }

  /// 根据允许分值范围规则，将分值钳制到合法范围内。
  double _clampQuickScore(double value) {
    final p = context.read<ScoreProvider>();
    switch (p.scoreRangeMode) {
      case 'only_add':
        return value < 0 ? 0 : value;
      case 'only_deduct':
        return value > 0 ? 0 : value;
      case 'custom':
        final lo = p.scoreRangeMin;
        final hi = p.scoreRangeMax;
        if (lo <= hi) return value.clamp(lo, hi).toDouble();
        return value;
      case 'unlimited':
      default:
        return value;
    }
  }

  /// 判断某个预设分值按钮在允许分值范围规则下是否显示。
  bool _presetAllowed(double value) {
    final p = context.read<ScoreProvider>();
    switch (p.scoreRangeMode) {
      case 'only_add':
        return value > 0;
      case 'only_deduct':
        return value < 0;
      case 'custom':
        return value >= p.scoreRangeMin && value <= p.scoreRangeMax;
      case 'unlimited':
      default:
        return true;
    }
  }

  /// 快速评分模式切换开关（紧凑版，与筛选小组下拉框同排右侧展示）
  Widget _buildQuickModeCompactToggle() {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: _quickMode ? Colors.green.shade50 : Colors.grey.shade100,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: _quickMode ? Colors.green : Colors.grey.shade300,
          width: _quickMode ? 1.5 : 1,
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _quickMode ? Icons.bolt : Icons.tune,
                size: 20,
                color: _quickMode
                    ? Colors.green.shade700
                    : Colors.grey.shade600,
              ),
              const SizedBox(width: 6),
              const Text('快速评分', style: TextStyle(fontWeight: FontWeight.bold)),
              GlassSwitch(
                value: _quickMode,
                onChanged: _setQuickMode,
                activeColor: Colors.green.withValues(alpha: 0.55),
                inactiveColor: Colors.black.withValues(alpha: 0.10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 快速评分：分值加减 + 预设按钮
  Widget _buildQuickScoreControls() {
    final displayValue = _clampQuickScore(_quickScore);
    final isPositive = displayValue >= 0;
    final sign = isPositive ? '+' : '-';
    final absText = (displayValue.abs() % 1 == 0)
        ? displayValue.abs().toStringAsFixed(0)
        : displayValue.abs().toString();

    const presetValues = [-3.0, -2.0, -1.0, 1.0, 2.0, 3.0];

    // 根据允许分值范围决定显示哪些快捷按钮
    final p = context.read<ScoreProvider>();
    final visiblePresets = presetValues.where(_presetAllowed).toList();
    // 加减按钮根据当前值判断是否可用：按下后得到的分值必须仍在允许范围内
    final minusEnabled = p.isScoreAllowed(_quickScore - 1);
    final plusEnabled = p.isScoreAllowed(_quickScore + 1);

    Widget stepperButton(IconData icon, VoidCallback? onTap, Color color) {
      return GlassIconAction(
        size: 64,
        iconSize: 40,
        icon: Icon(icon),
        onPressed: onTap,
        tintColor: color.withValues(alpha: 0.62),
        foregroundColor: Colors.white,
        variant: GlassActionVariant.prominent,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '分值（快速加减）',
          style: TextStyle(fontWeight: FontWeight.bold, height: 1.2),
        ),
        const SizedBox(height: 12),
        // 大号易触控的加减号与当前分值
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            stepperButton(
              Icons.remove,
              minusEnabled ? () => _setQuickScore(_quickScore - 1) : null,
              Colors.red.shade600,
            ),
            const SizedBox(width: 20),
            SizedBox(
              width: 160,
              child: Text(
                '$sign$absText',
                style: TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.bold,
                  color: isPositive
                      ? Colors.green.shade700
                      : Colors.red.shade700,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 20),
            stepperButton(
              Icons.add,
              plusEnabled ? () => _setQuickScore(_quickScore + 1) : null,
              Colors.green.shade600,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Center(
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: visiblePresets.map((v) {
              final isPos = v > 0;
              final label = isPos
                  ? '+${v.toStringAsFixed(0)}'
                  : v.toStringAsFixed(0);
              final color = isPos ? Colors.green : Colors.red;
              final isSelected = _quickScore == v;
              return SizedBox(
                width: 96,
                height: 52,
                child: GlassActionButton(
                  onPressed: () => _setQuickScore(v),
                  height: 52,
                  padding: EdgeInsets.zero,
                  foregroundColor: color.shade700,
                  tintColor: color.withValues(alpha: isSelected ? 0.28 : 0.12),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  child: Text(label),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isUnlocked = context.watch<AuthProvider>().isUnlocked;

    if (!isUnlocked) {
      return Scaffold(
        appBar: AppBar(toolbarHeight: 0),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                '请先解锁以使用评分录入功能',
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    final groups = context.watch<GroupProvider>().groups;
    final students = context.watch<StudentProvider>().students;
    final scoreItems = context.watch<ScoreItemProvider>().items;

    final filteredStudents = _selectedGroupId == null
        ? students
        : students.where((s) => s.groupId == _selectedGroupId).toList();

    // 已选择的学生数
    final selectedCount = _selectedStudentIds.length;

    // 当前周期
    final currentPeriod = context.watch<ScoreProvider>().currentPeriod;

    return Scaffold(
      appBar: AppBar(toolbarHeight: 0),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 筛选小组（左） + 快速评分切换（右，同一行、与下拉框本体对齐）
                const Text(
                  '筛选小组（可选）',
                  style: TextStyle(fontWeight: FontWeight.bold, height: 1.2),
                ),
                const SizedBox(height: 4),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 左侧：筛选小组下拉框
                      Expanded(
                        child: GlassDropdownField<int?>(
                          initialValue: _selectedGroupId,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            hintText: '不选择则显示所有学生',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: null,
                              child: Text('全部小组'),
                            ),
                            ...groups.map(
                              (g) => DropdownMenuItem(
                                value: g.id,
                                child: Text(g.name),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() {
                            _selectedGroupId = v;
                            // 筛选变化时，清除不在新范围内的已选学生
                            final filtered = v == null
                                ? students
                                : students.where((s) => s.groupId == v);
                            _selectedStudentIds.retainWhere(
                              (id) => filtered.any((s) => s.id == id),
                            );
                          }),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // 右侧：快速评分切换开关（与下拉框本体等高对齐）
                      _buildQuickModeCompactToggle(),
                    ],
                  ),
                ),

                const SizedBox(height: 10),

                // 学生选择区域
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '选择学生',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                      ),
                    ),
                    Row(
                      children: [
                        GlassActionButton(
                          onPressed: _selectAllStudents,
                          height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          fontSize: 13,
                          child: const Text('全选/取消'),
                        ),
                        const SizedBox(width: 4),
                        GlassActionButton.icon(
                          onPressed: _openAiRoster,
                          icon: const Icon(Icons.auto_awesome, size: 16),
                          label: const Text('AI 选学生'),
                          height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          fontSize: 13,
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: selectedCount > 0
                                ? Colors.green.shade50
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '已选 $selectedCount 人',
                            style: TextStyle(
                              color: selectedCount > 0
                                  ? Colors.green.shade700
                                  : Colors.grey.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const SizedBox(height: 4),
                // 根据容器宽度动态计算每行显示的学生数量
                LayoutBuilder(
                  builder: (ctx, constraints) {
                    // 卡片统一宽度：结果按「名单 + 可用宽度」缓存，点选学生
                    // （每次都会 setState 重建）不再重排全班文字。
                    final maxCardWidth = _resolveCardWidth(
                      filteredStudents,
                      constraints.maxWidth,
                    );

                    const textStyle = TextStyle(fontSize: 12);
                    return Wrap(
                      spacing: 8.0,
                      runSpacing: 8.0,
                      children: filteredStudents.map((s) {
                        final isSelected = _selectedStudentIds.contains(s.id);
                        // 选中时姓名变绿，学号跟随同色并降低不透明度
                        final nameColor = isSelected
                            ? Colors.green.shade700
                            : Colors.black87;
                        return GestureDetector(
                          onTap: () => _toggleStudentSelection(s.id!),
                          child: Container(
                            width: maxCardWidth,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Colors.green.shade50
                                  : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isSelected
                                    ? Colors.green
                                    : Colors.grey.shade300,
                                width: isSelected ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isSelected
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  size: 16,
                                  color: isSelected
                                      ? Colors.green
                                      : Colors.grey.shade600,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  // 姓名#学号（学号灰色；选中态跟随姓名色并降低不透明度）
                                  child: StudentNameText(
                                    name: s.name,
                                    studentNumber: s.studentNumber,
                                    style: textStyle.copyWith(
                                      fontWeight: isSelected
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                      color: nameColor,
                                    ),
                                    numberColor: StudentDisplay.numberColorFor(
                                      nameColor,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),

                const SizedBox(height: 10),

                // ===== 标准评分模式 =====
                if (!_quickMode) ...[
                  // 预设评分项
                  const Text(
                    '预设评分项（可选）',
                    style: TextStyle(fontWeight: FontWeight.bold, height: 1.2),
                  ),
                  const SizedBox(height: 4),
                  GlassDropdownField<int?>(
                    initialValue: _selectedItemId,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '选择预设（自动填充分值）',
                    ),
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: SizedBox(
                          height: 38,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text('自定义'),
                          ),
                        ),
                      ),
                      ...scoreItems.map((item) {
                        final score = item.defaultScore;
                        final Color scoreColor;
                        final String scoreLabel;
                        if (score > 0) {
                          scoreColor = Colors.green.shade700;
                          scoreLabel = '+${score.toStringAsFixed(1)}';
                        } else if (score < 0) {
                          scoreColor = Colors.red.shade700;
                          scoreLabel = score.toStringAsFixed(1);
                        } else {
                          scoreColor = Colors.grey.shade600;
                          scoreLabel = '0.0';
                        }
                        return DropdownMenuItem(
                          value: item.id,
                          child: SizedBox(
                            height: 38,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    item.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scoreColor.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    scoreLabel,
                                    style: TextStyle(
                                      color: scoreColor,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                    onChanged: (v) {
                      final item = v == null
                          ? null
                          : scoreItems.firstWhere((i) => i.id == v);
                      _onSelectPreset(item);
                    },
                  ),

                  const SizedBox(height: 12),

                  // 评分项名称和分值输入
                  if (_selectedItemId == null)
                    Row(
                      children: [
                        Expanded(
                          child: GlassInput(
                            controller: _customNameController,
                            label: '评分项名称',
                            hint: '如：考勤扣分、作业加分',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: GlassInput(
                            controller: _scoreController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                              signed: true,
                            ),
                            label: '分值',
                            hint: '请输入分值（支持小数，如 0.5 或 -1）',
                          ),
                        ),
                      ],
                    ),

                  const SizedBox(height: 10),

                  // 变动原因
                  const Text(
                    '变动原因',
                    style: TextStyle(fontWeight: FontWeight.bold, height: 1.2),
                  ),
                  const SizedBox(height: 4),
                  GlassTextAreaInput(
                    controller: _reasonController,
                    hint: '请输入评分原因（可选）',
                  ),
                ] else ...[
                  // ===== 快速评分模式 =====
                  _buildQuickScoreControls(),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
          // 底部提交按钮
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: GlassActionButton(
                onPressed: _loading ? null : _submit,
                height: 48,
                variant: GlassActionVariant.prominent,
                fontSize: 16,
                child: _loading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text('提交（$selectedCount人）'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
