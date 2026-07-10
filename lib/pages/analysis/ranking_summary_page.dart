import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/score_provider.dart';
import '../../providers/group_provider.dart';

class RankingSummaryPage extends StatefulWidget {
  const RankingSummaryPage({super.key});

  @override
  State<RankingSummaryPage> createState() => _RankingSummaryPageState();
}

class _RankingSummaryPageState extends State<RankingSummaryPage> {
  // 目标类型切换：学生/小组
  bool _showGroup = false;

  // 小组筛选
  int? _filterGroupId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GroupProvider>().loadGroups();
    });
  }

  /// 获取所有可用的周期选项
  List<int> _getAvailablePeriods() {
    final currentPeriod = context.read<ScoreProvider>().currentPeriod;
    return List.generate(currentPeriod, (i) => i + 1);
  }

  /// 格式化时间显示
  String _formatTime(String? isoTime) {
    if (isoTime == null || isoTime.isEmpty) return '暂无数据';
    try {
      final dt = DateTime.parse(isoTime);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return isoTime.substring(0, 16).replaceFirst('T', ' ');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scoreProvider = context.watch<ScoreProvider>();
    final groups = context.watch<GroupProvider>().groups;

    final periods = _getAvailablePeriods();
    final startPeriod = scoreProvider.advancedStartPeriod;
    final endPeriod = scoreProvider.advancedEndPeriod;
    final results = scoreProvider.advancedResults;
    final timeRange = scoreProvider.advancedTimeRange;

    return Scaffold(
      appBar: AppBar(
        title: const Text('高级查询'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 目标选择
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '查询类型',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          label: Text('个人'),
                          icon: Icon(Icons.person),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text('小组'),
                          icon: Icon(Icons.groups),
                        ),
                      ],
                      selected: {_showGroup},
                      onSelectionChanged: (v) {
                        setState(() {
                          _showGroup = v.first;
                          _filterGroupId = null;
                        });
                      },
                      style: const ButtonStyle(
                        iconSize: WidgetStatePropertyAll(18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // 小组筛选（仅学生模式显示）
            if (!_showGroup)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '筛选条件',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<int?>(
                        initialValue: _filterGroupId,
                        decoration: const InputDecoration(
                          labelText: '筛选小组',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          isDense: true,
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
                        onChanged: (v) async {
                          setState(() => _filterGroupId = v);
                          scoreProvider.setAdvancedGroupId(v);
                          // 自动执行查询（如果周期已选择）
                          if (startPeriod != null && endPeriod != null) {
                            scoreProvider.setAdvancedShowGroup(_showGroup);
                            await scoreProvider.executeAdvancedQuery();
                            if (mounted) {
                              setState(() {});
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),

            // 周期范围选择
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '周期范围',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '起始周期',
                                style: TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 4),
                              DropdownButtonFormField<int?>(
                                initialValue: startPeriod,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  isDense: true,
                                ),
                                items: periods
                                    .map(
                                      (p) => DropdownMenuItem(
                                        value: p,
                                        child: Text('第 $p 期'),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) async {
                                  scoreProvider.setAdvancedPeriodRange(
                                    v,
                                    endPeriod,
                                  );
                                  if (v != null &&
                                      (endPeriod == null || endPeriod < v)) {
                                    scoreProvider.setAdvancedPeriodRange(v, v);
                                  }
                                  // 自动执行查询：直接从 provider 获取最新值
                                  final newStart =
                                      scoreProvider.advancedStartPeriod;
                                  final newEnd =
                                      scoreProvider.advancedEndPeriod;
                                  if (newStart != null && newEnd != null) {
                                    scoreProvider.setAdvancedShowGroup(
                                      _showGroup,
                                    );
                                    await scoreProvider.executeAdvancedQuery();
                                    if (mounted) {
                                      setState(() {});
                                    }
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '结束周期',
                                style: TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 4),
                              DropdownButtonFormField<int?>(
                                initialValue: endPeriod,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  isDense: true,
                                ),
                                items: periods
                                    .map(
                                      (p) => DropdownMenuItem(
                                        value: p,
                                        child: Text('第 $p 期'),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) async {
                                  // 直接从 provider 获取最新的起始周期值（而不是 build 方法中的旧值）
                                  final currentStart =
                                      scoreProvider.advancedStartPeriod;
                                  final currentEnd =
                                      scoreProvider.advancedEndPeriod;

                                  if (v != null &&
                                      (currentStart == null ||
                                          v < currentStart)) {
                                    scoreProvider.setAdvancedPeriodRange(v, v);
                                  } else {
                                    scoreProvider.setAdvancedPeriodRange(
                                      currentStart,
                                      v,
                                    );
                                  }
                                  // 自动执行查询
                                  final newStart =
                                      scoreProvider.advancedStartPeriod;
                                  final newEnd =
                                      scoreProvider.advancedEndPeriod;
                                  if (newStart != null && newEnd != null) {
                                    scoreProvider.setAdvancedShowGroup(
                                      _showGroup,
                                    );
                                    await scoreProvider.executeAdvancedQuery();
                                    if (mounted) {
                                      setState(() {});
                                    }
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // 时间范围预览
                    if (startPeriod != null && endPeriod != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.calendar_today, size: 16),
                                const SizedBox(width: 8),
                                Text(
                                  '第 $startPeriod 期 至 第 $endPeriod 期',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Icon(
                                  Icons.arrow_upward,
                                  size: 14,
                                  color: Colors.green,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '首次评分: ${timeRange != null ? _formatTime(timeRange['first_score']) : '计算中...'}',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                const Icon(
                                  Icons.arrow_downward,
                                  size: 14,
                                  color: Colors.red,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '末次评分: ${timeRange != null ? _formatTime(timeRange['last_score']) : '计算中...'}',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),

                    // 清除按钮
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        onPressed: results.isEmpty
                            ? null
                            : () {
                                scoreProvider.clearAdvancedQuery();
                                setState(() => _filterGroupId = null);
                              },
                        icon: const Icon(Icons.clear_all, size: 18),
                        label: const Text('清除'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // 结果列表
            if (results.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            '查询结果',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '共 ${results.length} 条',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // 表头
                      Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: Text(
                              '排名',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.grey[700],
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              '名称',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.grey[700],
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 80,
                            child: Text(
                              '总分',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.grey[700],
                              ),
                              textAlign: TextAlign.end,
                            ),
                          ),
                        ],
                      ),
                      const Divider(),
                      // 数据行
                      ...results.asMap().entries.map((entry) {
                        final index = entry.key;
                        final r = entry.value;
                        final score = (r['total_score'] as num).toDouble();
                        final name = r['name'] as String;

                        // 学生模式下显示分组信息
                        String subtitle = '';
                        if (!_showGroup) {
                          subtitle = r['group_name'] as String? ?? '';
                        }

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              // 排名
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: index == 0
                                      ? Colors.amber
                                      : index == 1
                                      ? Colors.grey[300]
                                      : index == 2
                                      ? Colors.orange[200]
                                      : Colors.grey[200],
                                ),
                                child: Center(
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: index < 3
                                          ? Colors.black87
                                          : Colors.grey[700],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // 名称
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    if (subtitle.isNotEmpty)
                                      Text(
                                        subtitle,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              // 分数
                              SizedBox(
                                width: 80,
                                child: Text(
                                  score.toStringAsFixed(1),
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: score >= 0
                                        ? Colors.green
                                        : Colors.red,
                                  ),
                                  textAlign: TextAlign.end,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),

            // 暂无数据提示
            if (results.isEmpty && startPeriod != null && endPeriod != null)
              Card(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      children: [
                        Icon(
                          Icons.search_off,
                          size: 48,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '暂无数据',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '该周期范围内没有评分记录',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
