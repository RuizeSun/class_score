import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/score_item.dart';
import '../../providers/group_provider.dart';
import '../../providers/student_provider.dart';
import '../../providers/score_provider.dart';
import '../../providers/score_item_provider.dart';
import '../../providers/auth_provider.dart';

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

  Future<void> _switchToNextPeriod() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换到下一周期'),
        content: const Text(
          '即将切换到下一评分周期，当前周期的评分记录将保留，但下一周期的评分记录将被清空。\n\n确认切换吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
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
                child: Text(
                  s.studentNumber.isNotEmpty
                      ? '${s.name} (${s.studentNumber})'
                      : s.name,
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
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

  /// 快速评分模式切换开关
  Widget _buildQuickModeToggle() {
    return Card(
      elevation: 0,
      color: _quickMode ? Colors.green.shade50 : Colors.grey.shade100,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: _quickMode ? Colors.green : Colors.grey.shade300,
          width: _quickMode ? 1.5 : 1,
        ),
      ),
      child: SwitchListTile(
        secondary: Icon(
          _quickMode ? Icons.bolt : Icons.tune,
          color: _quickMode ? Colors.green.shade700 : Colors.grey.shade600,
        ),
        title: const Text(
          '快速评分',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          _quickMode
              ? '使用快速加减分，无需预设评分项（可后续补充原因）'
              : '使用预设评分项进行评分',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        value: _quickMode,
        onChanged: _setQuickMode,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      ),
    );
  }

  /// 快速评分：分值加减 + 预设按钮
  Widget _buildQuickScoreControls() {
    final displayValue = _clampQuickScore(_quickScore);
    final isPositive = displayValue >= 0;
    final sign = isPositive ? '+' : '-';
    final absText =
        (displayValue.abs() % 1 == 0)
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
      final enabled = onTap != null;
      return Material(
        color: enabled ? color : Colors.grey.shade400,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 64,
            height: 64,
            child: Icon(icon, color: Colors.white, size: 40),
          ),
        ),
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
            final label = isPos ? '+${v.toStringAsFixed(0)}' : v.toStringAsFixed(0);
            final color = isPos ? Colors.green : Colors.red;
            final isSelected = _quickScore == v;
            return SizedBox(
              width: 96,
              height: 52,
              child: OutlinedButton(
                onPressed: () => _setQuickScore(v),
                style: OutlinedButton.styleFrom(
                  foregroundColor: color.shade700,
                  backgroundColor: isSelected ? color.withValues(alpha: 0.15) : null,
                  side: BorderSide(
                    color: isSelected ? color : color.shade200,
                    width: isSelected ? 2 : 1,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
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
                // 快速评分模式切换
                _buildQuickModeToggle(),
                const SizedBox(height: 16),

                // 筛选小组
                const Text(
                  '筛选小组（可选）',
                  style: TextStyle(fontWeight: FontWeight.bold, height: 1.2),
                ),
                const SizedBox(height: 4),
                DropdownButtonFormField<int?>(
                  initialValue: _selectedGroupId,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '不选择则显示所有学生',
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部小组')),
                    ...groups.map(
                      (g) => DropdownMenuItem(value: g.id, child: Text(g.name)),
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
                        TextButton(
                          onPressed: _selectAllStudents,
                          child: const Text('全选/取消'),
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
                    // 预计算所有卡片内容的最大宽度，实现统一宽度对齐
                    final textStyle = const TextStyle(fontSize: 12);
                    double maxCardWidth = 0;
                    for (final s in filteredStudents) {
                      final displayName = s.studentNumber.isNotEmpty
                          ? '${s.name}  ${s.studentNumber}'
                          : s.name;
                      final textPainter = TextPainter(
                        text: TextSpan(text: displayName, style: textStyle),
                        textDirection: TextDirection.ltr,
                      )..layout();
                      // 卡片内容宽度 = 图标(16) + 间距(6) + 文本宽度 + 水平内边距(16)
                      final cardWidth = 16.0 + 6.0 + textPainter.width + 16.0;
                      if (cardWidth > maxCardWidth) {
                        maxCardWidth = cardWidth;
                      }
                    }
                    // 限制最大宽度不超过可用宽度的 45%（保留 spacing 余量）
                    final maxAllowedWidth = (constraints.maxWidth - 8.0) * 0.45;
                    if (maxCardWidth > maxAllowedWidth) {
                      maxCardWidth = maxAllowedWidth;
                    }

                    return Wrap(
                      spacing: 8.0,
                      runSpacing: 8.0,
                      children: filteredStudents.map((s) {
                        final isSelected = _selectedStudentIds.contains(s.id);
                        final displayName = s.studentNumber.isNotEmpty
                            ? '${s.name}  ${s.studentNumber}'
                            : s.name;
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
                                  child: Text(
                                    displayName,
                                    style: textStyle.copyWith(
                                      fontWeight: isSelected
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                      color: isSelected
                                          ? Colors.green.shade700
                                          : Colors.black87,
                                    ),
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
                DropdownButtonFormField<int?>(
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
                        child: TextField(
                          controller: _customNameController,
                          decoration: const InputDecoration(
                            labelText: '评分项名称',
                            border: OutlineInputBorder(),
                            hintText: '如：考勤扣分、作业加分',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
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
                TextField(
                  controller: _reasonController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '请输入评分原因（可选）',
                  ),
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
              child: ElevatedButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        '提交（$selectedCount人）',
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
