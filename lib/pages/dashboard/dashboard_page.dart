import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../database/database_helper.dart';
import '../../providers/score_provider.dart';

class DashboardPage extends StatefulWidget {
  final VoidCallback? onNavigateToRecords;
  const DashboardPage({super.key, this.onNavigateToRecords});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  List<Map<String, dynamic>> _todayScores = [];
  List<Map<String, dynamic>> _todaySchedules = [];
  List<Map<String, dynamic>> _recentRecords = [];
  List<Map<String, dynamic>> _groupRanking = [];
  List<Map<String, dynamic>> _positiveDistribution = [];
  List<Map<String, dynamic>> _negativeDistribution = [];
  bool _loading = true;
  ScoreProvider? _scoreProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scoreProvider = context.read<ScoreProvider>();
      _scoreProvider?.addListener(_onScoreDataChanged);
      _loadDashboardData();
    });
  }

  @override
  void dispose() {
    _scoreProvider?.removeListener(_onScoreDataChanged);
    super.dispose();
  }

  void _onScoreDataChanged() {
    _loadDashboardData();
  }

  Future<void> _loadDashboardData() async {
    final db = DatabaseHelper.instance;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    final startTimestamp = today.toIso8601String();
    final endTimestamp = tomorrow.toIso8601String();

    try {
      // 1. 获取今天课表（只显示还未结束的课程）
      final weekday = now.weekday; // 1-7 (Monday=1, Sunday=7)
      final schedules = await db.getCourseSchedulesByWeekday(weekday);

      // 根据当前时间过滤，只显示还未结束的课程
      final currentTime =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      final todaySchedules = schedules.where((s) {
        final endTime = _normalizeTime(s['end_time'] as String);
        return endTime.compareTo(currentTime) >= 0;
      }).toList();

      if (mounted) {
        setState(() {
          _todaySchedules = todaySchedules;
        });
      }

      final currentPeriod = _scoreProvider?.currentPeriod;

      // 2. 获取今日所有评分记录
      final allRecords = await db.getScoreRecords(period: currentPeriod);
      final todayRecords = allRecords.where((record) {
        final createTime = record['create_time'] as String;
        return createTime.startsWith(startTimestamp.substring(0, 10));
      }).toList();

      if (mounted) {
        setState(() {
          _todayScores = todayRecords;
        });
      }

      // 3. 获取最近5条评分记录
      final recent = await db.getScoreRecords(period: currentPeriod);
      final recentRecords = recent.take(5).toList();
      if (mounted) {
        setState(() {
          _recentRecords = recentRecords;
        });
      }

      // 4. 获取小组排名（今日）- 使用数据库计算的成员分数总和
      final groupScores = await db.getGroupTotalScores(period: currentPeriod);
      // 从今日记录中提取每个学生的分数
      final studentTodayScores = <int, double>{};
      for (final r in _todayScores) {
        if (r['target_type'] == 'student' && r['target_id'] != null) {
          final studentId = r['target_id'] as int;
          final score = (r['score'] as num?)?.toDouble() ?? 0;
          studentTodayScores[studentId] =
              (studentTodayScores[studentId] ?? 0) + score;
        }
      }
      // 获取学生-小组映射
      final allStudents = await db.getStudents();
      final studentGroupMap = <int, int>{};
      for (final s in allStudents) {
        studentGroupMap[s['id'] as int] = s['group_id'] as int;
      }
      // 获取每个小组的成员数量
      final groupMemberCount = <int, int>{};
      for (final s in allStudents) {
        final groupId = s['group_id'] as int;
        groupMemberCount[groupId] = (groupMemberCount[groupId] ?? 0) + 1;
      }
      // 计算每个小组今日总分（成员今日分数之和）
      final groupTodayScores = <int, double>{};
      for (final g in groupScores) {
        groupTodayScores[g['id'] as int] = 0;
      }
      for (final entry in studentTodayScores.entries) {
        final studentId = entry.key;
        final score = entry.value;
        final groupId = studentGroupMap[studentId];
        if (groupId != null) {
          groupTodayScores[groupId] = (groupTodayScores[groupId] ?? 0) + score;
        }
      }
      final groupRanking =
          groupScores.map((g) {
            final groupId = g['id'] as int;
            return {
              'id': groupId,
              'name': g['name'],
              'total_score': groupTodayScores[groupId] ?? 0,
            };
          }).toList()..sort(
            (a, b) => (b['total_score'] as double).compareTo(
              a['total_score'] as double,
            ),
          );

      // 过滤：如果"未分组"中没有成员，则隐藏该组
      final filteredGroupRanking = groupRanking.where((group) {
        final groupName = group['name'] as String;
        final groupId = group['id'] as int;
        if (groupName == '未分组') {
          final memberCount = groupMemberCount[groupId] ?? 0;
          return memberCount > 0;
        }
        return true;
      }).toList();

      if (mounted) {
        setState(() {
          _groupRanking = filteredGroupRanking;
        });
      }

      // 5. 获取全班加分分布
      final positiveDist = await db.getScoreDistributionByItem(
        targetType: 'student',
        startDate: startTimestamp,
        endDate: endTimestamp,
        period: currentPeriod,
      );
      final positiveData = positiveDist
          .where((d) => (d['total_score'] as num).toDouble() > 0)
          .take(6)
          .toList();

      if (mounted) {
        setState(() {
          _positiveDistribution = positiveData;
        });
      }

      // 6. 获取全班扣分分布
      final negativeData = positiveDist
          .where((d) => (d['total_score'] as num).toDouble() < 0)
          .take(6)
          .toList();

      if (mounted) {
        setState(() {
          _negativeDistribution = negativeData;
        });
      }
    } catch (e) {
      debugPrint('Dashboard load error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // 计算今日总分
    final totalPositive = _todayScores
        .where((r) => (r['score'] as num).toDouble() > 0)
        .fold<double>(0, (sum, r) => sum + ((r['score'] as num).toDouble()));
    final totalNegative = _todayScores
        .where((r) => (r['score'] as num).toDouble() < 0)
        .fold<double>(
          0,
          (sum, r) => sum + ((r['score'] as num).toDouble().abs()),
        );

    final now = DateTime.now();
    final weekDays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    final weekDayName = weekDays[now.weekday - 1];

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _loadDashboardData,
        child: CustomScrollView(
          slivers: [
            // 卡片网格 — 磁贴设计系统
            SliverPadding(
              padding: const EdgeInsets.all(24),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  // 1280x960 固定尺寸下实现 3 列: (1280-48-40)/3 ≈ 397
                  maxCrossAxisExtent: 397,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 20,
                  childAspectRatio: 1.6,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  switch (index) {
                    case 0:
                      return _DateScheduleCard(
                        date: now,
                        weekDayName: weekDayName,
                        schedules: _todaySchedules,
                      );
                    case 1:
                      return _RecentScoresCard(
                        records: _recentRecords,
                        onTap: widget.onNavigateToRecords,
                      );
                    case 2:
                      return _TotalScoresCard(
                        positive: totalPositive,
                        negative: totalNegative,
                      );
                    case 3:
                      return _GroupRankingCard(ranking: _groupRanking);
                    case 4:
                      return _PieChartCard(
                        title: '今日加分分布',
                        distribution: _positiveDistribution,
                        isPositive: true,
                      );
                    case 5:
                      return _PieChartCard(
                        title: '今日扣分分布',
                        distribution: _negativeDistribution,
                        isPositive: false,
                      );
                    default:
                      return const SizedBox();
                  }
                }, childCount: 6),
              ),
            ),
            // 底部占位
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
        ),
      ),
    );
  }
}

// ========== 卡片1: 日期与课表 ==========
class _DateScheduleCard extends StatelessWidget {
  final DateTime date;
  final String weekDayName;
  final List<Map<String, dynamic>> schedules;

  const _DateScheduleCard({
    required this.date,
    required this.weekDayName,
    required this.schedules,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr = '${date.year}年${date.month}月${date.day}日';

    return _CardWidget(
      icon: Icons.calendar_today,
      iconColor: Colors.blue,
      title: '日期与课表',
      surfaceColor: Colors.blue.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            dateStr,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          Text(
            weekDayName,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          if (schedules.isEmpty)
            _EmptyStateWidget()
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 显示前N节课程，如果超过3节则显示滚动区域
                ...schedules.take(3).map((s) {
                  final courseName = s['course_name'] as String;
                  final startTime = s['start_time'] as String;
                  final endTime = s['end_time'] as String;
                  return Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(
                            color: Colors.blue,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '$courseName $startTime-$endTime',
                            style: const TextStyle(fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                // 如果课程超过3节，显示"查看更多"提示
                if (schedules.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '共${schedules.length}节课，上拉查看全部',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey[500],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// ========== 卡片2: 最近评分 ==========
class _RecentScoresCard extends StatelessWidget {
  final List<Map<String, dynamic>> records;
  final VoidCallback? onTap;

  const _RecentScoresCard({required this.records, this.onTap});

  @override
  Widget build(BuildContext context) {
    final card = _CardWidget(
      icon: Icons.history,
      iconColor: Colors.purple,
      title: '最近评分',
      surfaceColor: Colors.purple.shade50,
      child: records.isEmpty
          ? _EmptyStateWidget()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: records.map((r) {
                final score = (r['score'] as num).toDouble();
                final targetName = r['target_name'] as String? ?? '未知';
                final reason = r['reason'] as String? ?? '';
                final scoreItemName =
                    r['score_item_name'] as String? ??
                    r['custom_name'] as String? ??
                    '-';

                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          color: score >= 0 ? Colors.green : Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$targetName · $scoreItemName',
                              style: const TextStyle(fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (reason.isNotEmpty)
                              Text(
                                reason,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey[600],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      Text(
                        score >= 0
                            ? '+${score.toInt()}'
                            : score.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: score >= 0 ? Colors.green : Colors.red,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: card);
    }
    return card;
  }
}

// ========== 卡片3: 今日总加分/总扣分 ==========
class _TotalScoresCard extends StatelessWidget {
  final double positive;
  final double negative;

  const _TotalScoresCard({required this.positive, required this.negative});

  @override
  Widget build(BuildContext context) {
    return _CardWidget(
      icon: Icons.analytics,
      iconColor: Colors.orange,
      title: '今日总分',
      surfaceColor: Colors.green.shade50,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _ScoreItem(
              label: '总加分',
              value: positive,
              color: Colors.green,
              icon: Icons.arrow_upward,
            ),
            const SizedBox(width: 16),
            Container(width: 1, height: 50, color: Colors.grey[300]),
            const SizedBox(width: 16),
            _ScoreItem(
              label: '总扣分',
              value: negative,
              color: Colors.red,
              icon: Icons.arrow_downward,
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreItem extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  final IconData icon;

  const _ScoreItem({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(
          '$value',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
      ],
    );
  }
}

// ========== 卡片4: 小组排名 ==========
class _GroupRankingCard extends StatelessWidget {
  final List<Map<String, dynamic>> ranking;

  const _GroupRankingCard({required this.ranking});

  @override
  Widget build(BuildContext context) {
    return _CardWidget(
      icon: Icons.groups,
      iconColor: Colors.teal,
      title: '今日小组排名',
      surfaceColor: Colors.orange.shade50,
      child: ranking.isEmpty
          ? _EmptyStateWidget()
          : ListView.builder(
              shrinkWrap: true,
              // 如果希望卡片内部能上下滚动查看超出的小组，可以删除下面这一行
              // physics: const NeverScrollableScrollPhysics(),
              itemCount: ranking.take(5).length,
              itemBuilder: (context, index) {
                final group = ranking[index];
                final name = group['name'] as String;
                final score = (group['total_score'] as num).toDouble();
                final isTop = index == 0;
                final isSecond = index == 1;
                final isThird = index == 2;

                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: isTop
                              ? Colors.amber
                              : isSecond
                              ? Colors.grey[300]
                              : isThird
                              ? Colors.orange[300]
                              : Colors.grey[200],
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            '${index + 1}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isTop || isSecond || isThird
                                  ? Colors.white
                                  : Colors.grey[700],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        score.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: score >= 0 ? Colors.green : Colors.red,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

// ========== 卡片5&6: 饼形图 ==========
class _PieChartCard extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> distribution;
  final bool isPositive;

  const _PieChartCard({
    required this.title,
    required this.distribution,
    this.isPositive = false,
  });

  @override
  Widget build(BuildContext context) {
    return _CardWidget(
      icon: isPositive ? Icons.add_circle : Icons.remove_circle,
      iconColor: isPositive ? Colors.green : Colors.red,
      title: title,
      surfaceColor: isPositive ? Colors.teal.shade50 : Colors.amber.shade50,
      child: distribution.isEmpty
          ? _EmptyStateWidget()
          : Row(
              // 改变为左右布局
              children: [
                // 左侧饼图
                Expanded(
                  flex: 4,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: PieChart(
                      PieChartData(
                        sections: _buildPieSections(),
                        centerSpaceRadius: 20, // 缩小中心圆半径以适应紧凑空间
                        sectionsSpace: 0.5,
                        borderData: FlBorderData(show: false),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 右侧图例
                Expanded(
                  flex: 5,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _buildLegend(),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  List<PieChartSectionData> _buildPieSections() {
    final colors = isPositive
        ? [
            Colors.green,
            Colors.lightGreen,
            Colors.teal,
            Colors.cyan,
            Colors.blue,
            Colors.indigo,
          ]
        : [
            Colors.red,
            Colors.redAccent,
            Colors.orange,
            Colors.deepOrange,
            Colors.pink,
            Colors.purple,
          ];

    return distribution.asMap().entries.map((entry) {
      final i = entry.key;
      final item = entry.value;
      final score = (item['total_score'] as num).toDouble().abs();
      final total = distribution.fold<double>(
        0,
        (sum, item) => sum + ((item['total_score'] as num).toDouble().abs()),
      );
      final pct = total > 0 ? (score / total * 100) : 0.0;
      return PieChartSectionData(
        color: colors[i % colors.length],
        value: score,
        title: '',
        titleStyle: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
        radius: 50,
      );
    }).toList();
  }

  List<Widget> _buildLegend() {
    return distribution.map((item) {
      final itemName = item['item_name'] as String;
      final count = item['count'] as int? ?? 0;
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                itemName,
                style: const TextStyle(fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '$count次',
                style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }).toList();
  }
}

// ========== 空状态组件 — 磁贴设计系统 ==========
class _EmptyStateWidget extends StatelessWidget {
  const _EmptyStateWidget();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bar_chart, size: 40, color: Colors.grey.shade400),
          const SizedBox(height: 8),
          Text(
            '暂无数据',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}

// ========== 通用卡片组件 — 磁贴设计系统 ==========
class _CardWidget extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final Widget child;
  final Color surfaceColor;

  const _CardWidget({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.child,
    this.surfaceColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: iconColor),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}

/// Normalize a time string to HH:MM format (with leading zeros).
/// E.g. "8:0" -> "08:00", "9:30" -> "09:30"
String _normalizeTime(String time) {
  final parts = time.split(':');
  final hour = int.tryParse(parts[0]) ?? 0;
  final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

// ========== 工具函数 ==========
String _formatTime(String isoTime) {
  try {
    final dt = DateTime.parse(isoTime);
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  } catch (_) {
    return isoTime.substring(5); // 显示 MM-DD
  }
}
