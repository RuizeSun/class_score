import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../database/database_helper.dart';
import '../../providers/student_provider.dart';
import '../../providers/group_provider.dart';
import '../../providers/score_provider.dart';

class AnalysisView extends StatefulWidget {
  const AnalysisView({super.key});

  @override
  State<AnalysisView> createState() => _AnalysisViewState();
}

class _AnalysisViewState extends State<AnalysisView> {
  // 目标类型切换：学生/小组
  String _targetType = 'student'; // 'student' | 'group'

  // 筛选器
  int? _filterStudentId;
  int? _filterGroupId;
  String _timeRange = 'all'; // '7d', '30d', 'all'

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<StudentProvider>().loadStudents();
      context.read<GroupProvider>().loadGroups();
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

    _records = await db.getScoreRecordsAdvanced(
      targetType: _targetType,
      targetId: targetId,
      startDate: _startDate,
      endDate: _endDate,
      period: currentPeriod,
    );

    _distribution = await db.getScoreDistributionByItem(
      targetType: _targetType,
      targetId: targetId,
      startDate: _startDate,
      endDate: _endDate,
      period: currentPeriod,
    );

    _dailyAverages = await db.getAverageDailyScores(
      targetType: _targetType,
      targetId: targetId,
      period: currentPeriod,
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
              // 目标类型切换
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
                    const DropdownMenuItem(value: null, child: Text('全部学生')),
                    ...students.map(
                      (s) => DropdownMenuItem(
                        value: s.id,
                        child: Text(
                          s.studentNumber.isNotEmpty
                              ? '${s.name} (${s.studentNumber})'
                              : s.name,
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
                    const DropdownMenuItem(value: null, child: Text('全部小组')),
                    ...groups.map(
                      (g) => DropdownMenuItem(value: g.id, child: Text(g.name)),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => _filterGroupId = v);
                    _loadData();
                  },
                ),
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
                // Pie charts - score distribution (positive and negative separated, side by side)
                Text(
                  _targetType == 'student' ? '评分项分布（按分值占比）' : '评分项分布（按分值占比）',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    // 加分项饼图 - 左半部分
                    Expanded(
                      flex: 3,
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
                                ? const Center(child: Text('暂无加分项'))
                                : PieChart(
                                    PieChartData(
                                      sections: _buildPositivePieSections(),
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
                      flex: 3,
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
                                ? const Center(child: Text('暂无扣分项'))
                                : PieChart(
                                    PieChartData(
                                      sections: _buildNegativePieSections(),
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

                const SizedBox(height: 24),

                // Total scores
                const Text(
                  '总加分/总扣分统计',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
                  ...(_records.take(100).map((r) {
                    final score = (r['score'] as num).toDouble();
                    final time = (r['create_time'] as String)
                        .replaceFirst('T', ' ')
                        .substring(0, 19);
                    final itemName =
                        r['score_item_name'] as String? ??
                        r['custom_name'] as String? ??
                        '-';
                    // 根据 targetType 显示不同的名称
                    String displayName;
                    if (_targetType == 'group') {
                      displayName = r['target_name'] as String? ?? '(未知)';
                    } else {
                      final studentNumber =
                          r['target_student_number'] as String? ?? '';
                      displayName = studentNumber.isNotEmpty
                          ? '${r['target_name'] ?? '(未知)'} ($studentNumber)'
                          : '${r['target_name'] ?? '(未知)'}';
                    }
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      child: ListTile(
                        dense: true,
                        title: Text(
                          '$displayName  •  $itemName',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '${r['reason'] ?? ''}\n$time',
                          style: const TextStyle(fontSize: 11),
                          maxLines: 2,
                        ),
                        trailing: Text(
                          score.toStringAsFixed(1),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: score >= 0 ? Colors.green : Colors.red,
                          ),
                        ),
                      ),
                    );
                  })),
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
    final total = positiveData.fold<double>(
      0,
      (sum, item) => sum + ((item['total_score'] as num?)?.toDouble() ?? 0),
    );

    return positiveData.asMap().entries.map((entry) {
      final i = entry.key;
      final item = entry.value;
      final score = (item['total_score'] as num).toDouble();
      final pct = total > 0 ? (score / total * 100) : 0.0;
      return PieChartSectionData(
        color: colors[i % colors.length],
        value: score,
        title: '${pct.toStringAsFixed(0)}%',
        titleStyle: const TextStyle(
          color: Colors.white,
          fontSize: 11,
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
    final total = negativeData.fold<double>(
      0,
      (sum, item) =>
          sum + ((item['total_score'] as num?)?.toDouble() ?? 0).abs(),
    );

    return negativeData.asMap().entries.map((entry) {
      final i = entry.key;
      final item = entry.value;
      final score = (item['total_score'] as num).toDouble().abs();
      final pct = total > 0 ? (score / total * 100) : 0.0;
      return PieChartSectionData(
        color: colors[i % colors.length],
        value: score,
        title: '${pct.toStringAsFixed(0)}%',
        titleStyle: const TextStyle(
          color: Colors.white,
          fontSize: 11,
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
    return positiveData.asMap().entries.map((entry) {
      final i = entry.key;
      final item = entry.value;
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
    return negativeData.asMap().entries.map((entry) {
      final i = entry.key;
      final item = entry.value;
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
        ],
      );
    }).toList();
  }
}
