import 'package:flutter/material.dart';
import 'analysis_page.dart';

/// 图表分析独立页面。
///
/// 由「查询 → 统计报表」跳转进入：
/// - 指定 [targetId]：展示单个学生/小组的图表分析（隐藏目标切换控件）；
/// - [targetId] 为空：等同原「图表分析」Tab 的班级视图（保留学生/小组切换与筛选控件）。
class AnalysisDetailPage extends StatelessWidget {
  const AnalysisDetailPage({
    super.key,
    this.targetType = 'student',
    this.targetId,
    this.title = '图表分析',
  });

  /// 目标类型：'student' | 'group'
  final String targetType;

  /// 目标 ID；为 null 表示「全部」
  final int? targetId;

  /// 页面标题
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundColor: theme.colorScheme.onPrimaryContainer,
      ),
      // 单一目标（详情）时隐藏目标切换控件，全部视图保留筛选能力
      body: AnalysisView(
        initialTargetType: targetType,
        initialTargetId: targetId,
        showTargetSelector: targetId == null,
      ),
    );
  }
}
