import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../database/database_helper.dart';
import '../../providers/auth_provider.dart';
import '../../providers/student_provider.dart';
import '../../providers/group_provider.dart';
import '../../providers/score_item_provider.dart';
import '../../providers/score_provider.dart';
import '../../widgets/score_record_tile.dart';
import '../../widgets/student_name_text.dart';

class AnalysisView extends StatefulWidget {
  const AnalysisView({
    super.key,
    this.initialTargetType = 'student',
    this.initialTargetId,
    this.showTargetSelector = true,
  });

  /// 初始目标类型：'student' | 'group'
  final String initialTargetType;

  /// 初始目标 ID；为 null 表示「全部」
  final int? initialTargetId;

  /// 是否显示学生/小组切换与筛选控件。
  /// 从统计报表点击某个学生/小组进入时隐藏，仅展示该目标的图表。
  final bool showTargetSelector;

  @override
  State<AnalysisView> createState() => _AnalysisViewState();
}

class _AnalysisViewState extends State<AnalysisView> {
  // 目标类型切换：学生/小组
  late String _targetType; // 'student' | 'group'

  // 筛选器
  int? _filterStudentId;
  int? _filterGroupId;
  String _timeRange = 'all'; // '7d', '30d', 'all'

  /// 仅「小组 + 全部小组」视图可用：
  /// 统计时是否排除"不参与小组总分"（未参加小组评分）的学生记录。
  bool _excludeNotInGroupTotal = true;

  // Data
  List<Map<String, dynamic>> _records = [];
  List<Map<String, dynamic>> _distribution = [];
  Map<String, dynamic> _dailyAverages = {};
  bool _loading = false;

  String? _startDate;
  String? _endDate;

  @override
  void initState() {
    super.initState();
    // 按外部指定的目标初始化（点击统计报表中的学生/小组进入时）
    _targetType = widget.initialTargetType;
    if (_targetType == 'group') {
      _filterGroupId = widget.initialTargetId;
    } else {
      _filterStudentId = widget.initialTargetId;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<StudentProvider>().loadStudents();
      context.read<GroupProvider>().loadGroups();
      // 编辑记录对话框需要评分项预设列表
      context.read<ScoreItemProvider>().loadItems();
      _loadData();
    });
  }

  void _updateTimeRange() {
    final now = DateTime.now();
    switch (_timeRange) {
      case '7d':
        _startDate = now
            .subtract(const Duration(days: 7))
            .toIso8601String()
            .substring(0, 10);
        _endDate = null;
        break;
      case '30d':
        _startDate = now
            .subtract(const Duration(days: 30))
            .toIso8601String()
            .substring(0, 10);
        _endDate = null;
        break;
      default:
        _startDate = null;
        _endDate = null;
    }
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    _updateTimeRange();

    final db = DatabaseHelper.instance;

    // 根据 targetType 选择筛选 ID
    final targetId = _targetType == 'student'
        ? _filterStudentId
        : _filterGroupId;

    final currentPeriod = context.read<ScoreProvider>().currentPeriod;

    // 小组维度统计：选中具体小组时强制排除"不参与小组总分"的学生记录，
    // 选择「全部小组」时由开关 _excludeNotInGroupTotal 决定。
    final excludeNotInGroupTotal =
        _targetType == 'group' &&
        (_filterGroupId != null || _excludeNotInGroupTotal);

    _records = await db.getScoreRecordsAdvanced(
      targetType: _targetType,
      targetId: targetId,
      startDate: _startDate,
      endDate: _endDate,
      period: currentPeriod,
      excludeNotInGroupTotal: excludeNotInGroupTotal,
    );

    _distribution = await db.getScoreDistributionByItem(
      targetType: _targetType,
      targetId: targetId,
      startDate: _startDate,
      endDate: _endDate,
      period: currentPeriod,
      excludeNotInGroupTotal: excludeNotInGroupTotal,
    );

    _dailyAverages = await db.getAverageDailyScores(
      targetType: _targetType,
      targetId: targetId,
      period: currentPeriod,
      excludeNotInGroupTotal: excludeNotInGroupTotal,
    );

    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final students = context.watch<StudentProvider>().students;
    final groups = context.watch<GroupProvider>().groups;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // 筛选区域
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              // 目标类型切换与筛选（单个目标详情页隐藏）
              if (widget.showTargetSelector) ...[
                Center(
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'student',
                        label: Text('学生'),
                        icon: Icon(Icons.person),
                      ),
                      ButtonSegment(
                        value: 'group',
                        label: Text('小组'),
                        icon: Icon(Icons.groups),
                      ),
                    ],
                    selected: {_targetType},
                    onSelectionChanged: (v) {
                      setState(() {
                        _targetType = v.first;
                        // 切换时重置筛选
                        if (_targetType == 'student') {
                          _filterStudentId = null;
                        } else {
                          _filterGroupId = null;
                        }
                      });
                      _loadData();
                    },
                    style: const ButtonStyle(
                      iconSize: WidgetStatePropertyAll(18),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // 根据目标类型显示不同的筛选下拉框
                if (_targetType == 'student')
                  DropdownButtonFormField<int?>(
                    decoration: const InputDecoration(
                      labelText: '筛选学生',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      isDense: true,
                    ),
                    initialValue: _filterStudentId,
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('全部学生'),
                      ),
                      ...students.map(
                        (s) => DropdownMenuItem(
                          value: s.id,
                          // 姓名#学号（学号灰色）
                          child: StudentNameText(
                            name: s.name,
                            studentNumber: s.studentNumber,
                          ),
                        ),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() => _filterStudentId = v);
                      _loadData();
                    },
                  )
                else
                  DropdownButtonFormField<int?>(
                    decoration: const InputDecoration(
                      labelText: '筛选小组',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      isDense: true,
                    ),
                    initialValue: _filterGroupId,
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('全部小组'),
                      ),
                      ...groups.map(
                        (g) =>
                            DropdownMenuItem(value: g.id, child: Text(g.name)),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() => _filterGroupId = v);
                      _loadData();
                    },
                  ),
                // 「全部小组」视图下可选择是否统计未参加小组评分的学生
                if (_targetType == 'group' && _filterGroupId == null) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _excludeNotInGroupTotal,
                    title: const Text(
                      '统计时排除未参加小组评分的学生',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      '关闭后将包含这些学生的评分记录与分值',
                      style: TextStyle(fontSize: 11),
                    ),
                    onChanged: (v) {
                      setState(() => _excludeNotInGroupTotal = v);
                      _loadData();
                    },
                  ),
                ],
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('时间范围：'),
                  const SizedBox(width: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'all', label: Text('全部')),
                      ButtonSegment(value: '7d', label: Text('最近 7 天')),
                      ButtonSegment(value: '30d', label: Text('最近 30 天')),
                    ],
                    selected: {_timeRange},
                    onSelectionChanged: (v) {
                      _timeRange = v.first;
                      _loadData();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),

        // Content
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 评分项分布（左栏）与汇总统计（右栏）并排，提升信息密度
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ===== 左栏：评分项分布 =====
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '评分项分布（按分值占比）',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              // 加分项饼图 - 左半部分
                              Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      '加分项',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: Colors.green,
                                      ),
                                    ),
                                    SizedBox(
                                      height: 200,
                                      child: _getPositiveDistribution().isEmpty
                                          ? const Center(
                                              child: Text('暂无加分项'),
                                            )
                                          : PieChart(
                                              PieChartData(
                                                sections:
                                                    _buildPositivePieSections(),
                                                centerSpaceRadius: 40,
                                                sectionsSpace: 2,
                                              ),
                                            ),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: _buildPositiveLegend(),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              // 扣分项饼图 - 右半部分
                              Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      '扣分项',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: Colors.red,
                                      ),
                                    ),
                                    SizedBox(
                                      height: 200,
                                      child: _getNegativeDistribution().isEmpty
                                          ? const Center(
                                              child: Text('暂无扣分项'),
                                            )
                                          : PieChart(
                                              PieChartData(
                                                sections:
                                                    _buildNegativePieSections(),
                                                centerSpaceRadius: 40,
                                                sectionsSpace: 2,
                                              ),
                                            ),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: _buildNegativeLegend(),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(width: 16),

                    // ===== 右栏：总加分/总扣分 与 日均加分/扣分 =====
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '总加分/总扣分统计',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      children: [
                                        Text(
                                          ((_dailyAverages['total_positive'] as num?)
                                                      ?.toDouble() ??
                                                  0.0)
                                              .toStringAsFixed(1),
                                          style: const TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green,
                                          ),
                                        ),
                                        const Text('总加分'),
                                      ],
                                    ),
                                  ),
                                  const VerticalDivider(),
                                  Expanded(
                                    child: Column(
                                      children: [
                                        Text(
                                          ((_dailyAverages['total_negative'] as num?)
                                                      ?.toDouble() ??
                                                  0.0)
                                              .toStringAsFixed(1),
                                          style: const TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.red,
                                          ),
                                        ),
                                        const Text('总扣分'),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // Average daily scores
                          const Text(
                            '日均加分/扣分统计',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      children: [
                                        Text(
                                          ((_dailyAverages['avg_positive'] as num?)
                                                      ?.toDouble() ??
                                                  0.0)
                                              .toStringAsFixed(1),
                                          style: const TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green,
                                          ),
                                        ),
                                        const Text('日均加分'),
                                      ],
                                    ),
                                  ),
                                  const VerticalDivider(),
                                  Expanded(
                                    child: Column(
                                      children: [
                                        Text(
                                          ((_dailyAverages['avg_negative'] as num?)
                                                      ?.toDouble() ??
                                                  0.0)
                                              .toStringAsFixed(1),
                                          style: const TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.red,
                                          ),
                                        ),
                                        const Text('日均扣分'),
                                      ],
                                    ),
                                  ),
                                  const VerticalDivider(),
                                  Expanded(
                                    child: Column(
                                      children: [
                                        Text(
                                          '${_dailyAverages['scored_days']}',
                                          style: const TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const Text('有评分天数'),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Records table
                Text(
                  '评分变动记录',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 8),
                if (_records.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('暂无记录'),
                    ),
                  )
                else
                  // 条目样式与操作逻辑复用「记录管理」的 ScoreRecordTile
                  ...(_records.take(100).map(
                    (r) => ScoreRecordTile(
                      record: r,
                      isUnlocked: context.watch<AuthProvider>().isUnlocked,
                      onMutated: _loadData,
                    ),
                  )),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 获取加分项分布数据
  List<Map<String, dynamic>> _getPositiveDistribution() {
    return _distribution
        .where((d) => (d['total_score'] as num).toDouble() > 0)
        .take(8)
        .toList();
  }

  // 获取扣分项分布数据
  List<Map<String, dynamic>> _getNegativeDistribution() {
    return _distribution
        .where((d) => (d['total_score'] as num).toDouble() < 0)
        .take(8)
        .toList();
  }

  // 加分项变动值总量（正数合计）
  double _positiveTotal() {
    return _getPositiveDistribution().fold<double>(
      0,
      (sum, item) => sum + ((item['total_score'] as num?)?.toDouble() ?? 0),
    );
  }

  // 扣分项变动值总量（负数取绝对值后合计）
  double _negativeTotal() {
    return _getNegativeDistribution().fold<double>(
      0,
      (sum, item) => sum + ((item['total_score'] as num?)?.toDouble() ?? 0).abs(),
    );
  }

  // 变动值文本：正数带 + 号，保留 1 位小数
  String _fmtChangeValue(double v) {
    if (v > 0) return '+${v.toStringAsFixed(1)}';
    if (v < 0) return v.toStringAsFixed(1);
    return '0.0';
  }

  // 构建加分饼图数据
  List<PieChartSectionData> _buildPositivePieSections() {
    final colors = [
      Colors.green,
      Colors.lightGreen,
      Colors.teal,
      Colors.cyan,
      Colors.blue,
      Colors.indigo,
      Colors.purple,
      Colors.deepPurple,
    ];

    final positiveData = _getPositiveDistribution();
    final total = _positiveTotal();

    return positiveData.asMap().entries.map((entry) {
      final i = entry.key;
      final item = entry.value;
      final score = (item['total_score'] as num).toDouble();
      final pct = total > 0 ? (score / total * 100) : 0.0;
      return PieChartSectionData(
        color: colors[i % colors.length],
        value: score,
        // 扇区内两行显示：变动值总量（带 + 号） + 百分比
        title: '${_fmtChangeValue(score)}\n${pct.toStringAsFixed(0)}%',
        titleStyle: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          height: 1.1,
          fontWeight: FontWeight.bold,
        ),
        radius: 60,
      );
    }).toList();
  }

  // 构建扣分饼图数据
  List<PieChartSectionData> _buildNegativePieSections() {
    final colors = [
      Colors.red,
      Colors.redAccent,
      Colors.orange,
      Colors.deepOrange,
      Colors.pink,
      Colors.purple,
      Colors.indigo,
      Colors.blue,
    ];

    final negativeData = _getNegativeDistribution();
    final total = _negativeTotal();

    return negativeData.asMap().entries.map((entry) {
      final i = entry.key;
      final item = entry.value;
      // 原始带符号的变动值（用于文字展示），取绝对值用于扇区占比
      final signedScore = (item['total_score'] as num).toDouble();
      final score = signedScore.abs();
      final pct = total > 0 ? (score / total * 100) : 0.0;
      return PieChartSectionData(
        color: colors[i % colors.length],
        value: score,
        // 扇区内两行显示：变动值总量（带负号） + 百分比
        title: '${_fmtChangeValue(signedScore)}\n${pct.toStringAsFixed(0)}%',
        titleStyle: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          height: 1.1,
          fontWeight: FontWeight.bold,
        ),
        radius: 60,
      );
    }).toList();
  }

  // 构建加分图例
  List<Widget> _buildPositiveLegend() {
    final colors = [
      Colors.green,
      Colors.lightGreen,
      Colors.teal,
      Colors.cyan,
      Colors.blue,
      Colors.indigo,
      Colors.purple,
      Colors.deepPurple,
    ];

    final positiveData = _getPositiveDistribution();
    return _buildDistributionLegend(
      data: positiveData,
      colors: colors,
      total: _positiveTotal(),
    );
  }

  // 构建分布图例：评分项名称 + 变动值总量（带正负号） + 百分比
  List<Widget> _buildDistributionLegend({
    required List<Map<String, dynamic>> data,
    required List<Color> colors,
    required double total,
  }) {
    return data.asMap().entries.map((entry) {
      final i = entry.key;
      final item = entry.value;
      final score = (item['total_score'] as num).toDouble();
      final pct = total > 0 ? (score.abs() / total * 100) : 0.0;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: colors[i % colors.length],
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            item['item_name'] as String,
            style: const TextStyle(fontSize: 11),
          ),
          const SizedBox(width: 4),
          Text(
            '${_fmtChangeValue(score)}（${pct.toStringAsFixed(0)}%）',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: score >= 0 ? Colors.green.shade700 : Colors.red.shade700,
            ),
          ),
        ],
      );
    }).toList();
  }

  // 构建扣分图例
  List<Widget> _buildNegativeLegend() {
    final colors = [
      Colors.red,
      Colors.redAccent,
      Colors.orange,
      Colors.deepOrange,
      Colors.pink,
      Colors.purple,
      Colors.indigo,
      Colors.blue,
    ];

    final negativeData = _getNegativeDistribution();
    return _buildDistributionLegend(
      data: negativeData,
      colors: colors,
      total: _negativeTotal(),
    );
  }
}
