import 'package:flutter/material.dart';

/// 分栏面板的栏头：图标 + 标题（+ 可选操作区）。
///
/// 「查询」页改为左右分栏后，原来的 Tab（统计报表 / 记录管理）由每栏的
/// 栏头承担，保证两栏身份清晰、且两栏风格一致。
class PaneHeader extends StatelessWidget {
  const PaneHeader({
    super.key,
    required this.icon,
    required this.title,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(12, 12, 12, 8),
  });

  final IconData icon;
  final String title;

  /// 栏头右侧操作区（可选）。
  final List<Widget> actions;

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
