import 'package:flutter/material.dart';

import 'student_name_text.dart';

/// 「统计报表」排名榜单的布局常量。
///
/// 学生榜与小组榜共用同一套尺寸与间距，保证两个视图的行高、
/// 名次分组间距、卡片宽度完全一致（历史上两个列表各写一套 [ListTile]：
/// 学生行带副标题 → 64，小组行无副标题 → 48，行距因此不统一）。
class RankingMetrics {
  RankingMetrics._();

  /// 行高（学生行与小组行都是「主标题 + 副标题」两行结构）。
  static const double rowHeight = 60;

  /// 名次徽章直径。
  static const double badgeSize = 36;

  /// 分数列宽度。
  static const double scoreWidth = 88;

  /// 徽章与名称之间的水平间距。
  static const double badgeGap = 12;

  /// 行内水平内边距（名次组容器内）。
  static const double rowPadding = 12;

  /// 名次组容器圆角半径。
  static const double groupRadius = 12;

  /// 名次组容器内的上下内边距。
  static const double groupPadding = 4;

  /// 不同名次（名次组）之间的间距：留白，用于区分名次。
  static const double rankGroupSpacing = 8;

  /// 关闭「同名次合并」时每行之间的间距（每行独立成组）。
  static const double rowSpacing = 4;

  /// 榜单内容最大宽度：宽屏下居中，避免姓名与分数被整个窗口拉开。
  static const double contentMaxWidth = 760;

  /// 名次徽章底色：前三名为金 / 银 / 铜，其余沿用学生榜蓝、小组榜紫的淡色。
  static Color badgeColor({
    required int rank,
    required bool isGroup,
    required ColorScheme scheme,
  }) {
    switch (rank) {
      case 1:
        return Colors.amber;
      case 2:
        return Colors.grey.shade300;
      case 3:
        return Colors.orange.shade300;
      default:
        return isGroup ? Colors.purple.shade100 : Colors.blue.shade100;
    }
  }

  /// 名次徽章文字色（金 / 银 / 铜与淡色底都用深色文字保证可读性）。
  static const Color badgeForeground = Colors.black87;
}

/// 名次组容器：同一名次的所有行放在同一个圆角淡色块里。
///
/// 「同名次合并」开启时，并列的对象共处一块（组内紧贴、视觉上一眼可辨）；
/// 关闭时每组只含一行，块与块之间等距排列。
/// 组与组之间的间距由调用方按 [RankingMetrics.rankGroupSpacing] 控制。
class RankingGroup extends StatelessWidget {
  const RankingGroup({super.key, required this.children});

  /// 该名次下的所有行（[RankingTile]）。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(RankingMetrics.groupRadius),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: RankingMetrics.groupPadding,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// 榜单表头：与学生榜 / 小组榜的行内容（名称 / 总分）对齐。
class RankingListHeader extends StatelessWidget {
  const RankingListHeader({super.key, required this.title});

  /// 左列标题（学生榜为「学生」，小组榜为「小组」）。
  final String title;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: Colors.grey.shade600,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RankingMetrics.rowPadding,
        vertical: 6,
      ),
      child: Row(
        children: [
          // 与行内名称左对齐（留出名次徽章的位置）
          const SizedBox(
            width: RankingMetrics.badgeSize + RankingMetrics.badgeGap,
          ),
          Expanded(child: Text(title, style: style)),
          SizedBox(
            width: RankingMetrics.scoreWidth,
            child: Text('总分', textAlign: TextAlign.end, style: style),
          ),
        ],
      ),
    );
  }
}

/// 榜单空状态：学生榜 / 小组榜共用。
class RankingEmptyState extends StatelessWidget {
  const RankingEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.leaderboard_outlined,
            size: 48,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 12),
          Text(
            '暂无数据',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 4),
          Text(
            '当前评分周期还没有可统计的记录',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}

/// 统计报表「学生榜 / 小组榜」排名行的唯一实现。
///
/// 行内结构统一为「名次徽章 + 主标题 + 副标题 + 分数」，尺寸取自
/// [RankingMetrics]，因此两个榜单的行高与水平节奏完全一致。
class RankingTile extends StatelessWidget {
  /// 名次（从 1 开始，并列名次取相同值）。
  final int rank;

  /// 总分。
  final double score;

  /// 主标题：学生为姓名，小组为小组名。
  final String title;

  /// 学号；为空时只显示姓名（小组行为空）。
  final String studentNumber;

  /// 副标题：学生为所属小组，小组为成员数。
  final String subtitle;

  /// 副标题前的小图标（学生榜为小组图标，小组榜为成员图标）。
  final IconData subtitleIcon;

  /// 名次徽章底色（见 [RankingMetrics.badgeColor]）。
  final Color badgeColor;

  /// 是否处于选中态：左栏联动筛选右栏记录时高亮该行。
  final bool selected;

  /// 点击本行（联动筛选右侧记录列表）。
  final VoidCallback? onTap;

  /// 行尾「图表分析」图标入口；为空时不显示该图标。
  final VoidCallback? onOpenAnalysis;

  const RankingTile({
    super.key,
    required this.rank,
    required this.score,
    required this.title,
    required this.subtitle,
    required this.subtitleIcon,
    required this.badgeColor,
    this.studentNumber = '',
    this.selected = false,
    this.onTap,
    this.onOpenAnalysis,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nameStyle = theme.textTheme.bodyLarge?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final isPositive = score >= 0;

    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: RankingMetrics.rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: RankingMetrics.rowPadding,
            ),
            child: Row(
              children: [
                // 名次徽章：前三名为金 / 银 / 铜
                Container(
                  width: RankingMetrics.badgeSize,
                  height: RankingMetrics.badgeSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: badgeColor,
                  ),
                  child: Center(
                    child: Text(
                      '$rank',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: RankingMetrics.badgeForeground,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: RankingMetrics.badgeGap),
                // 名称 + 副标题（学生与小组都是两行结构，保证行高一致）
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StudentNameText(
                        name: title,
                        studentNumber: studentNumber,
                        style: nameStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(
                              subtitleIcon,
                              size: 13,
                              color: Colors.grey.shade600,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                // 分数
                SizedBox(
                  width: RankingMetrics.scoreWidth,
                  child: Text(
                    score.toStringAsFixed(1),
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: isPositive
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                    ),
                  ),
                ),
                // 行尾：打开该学生/小组的图表分析
                if (onOpenAnalysis != null)
                  IconButton(
                    tooltip: '图表分析',
                    onPressed: onOpenAnalysis,
                    icon: const Icon(Icons.insights_outlined, size: 20),
                    color: Colors.blueGrey,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
