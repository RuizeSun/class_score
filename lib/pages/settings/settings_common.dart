import 'package:flutter/material.dart';

/// 设置 Tab 的统一布局常量。
///
/// 设置页下的所有分项共用同一套页头、外边距与空状态样式，
/// 避免切换分项时出现间距、标题层级、操作入口位置跳变。
class SettingsLayout {
  SettingsLayout._();

  /// 页头外边距（标题 / 说明 / 操作区共用）。
  static const EdgeInsets headerPadding = EdgeInsets.fromLTRB(16, 16, 16, 0);

  /// 内容区外边距，同时作为工具栏与列表的水平 gutter。
  static const EdgeInsets contentPadding = EdgeInsets.fromLTRB(16, 0, 16, 16);

  /// 页头与内容之间的间距。
  static const double headerSpacing = 12;

  /// 页头标题字号。
  static const double headerTitleSize = 18;

  /// 分项内部区块标题字号。
  static const double sectionTitleSize = 16;

  /// 说明 / 次要提示文字字号。
  static const double hintFontSize = 13;

  /// 工具栏与内容之间的间距。
  static const double toolbarSpacing = 12;

  /// 分项内部区块之间的间距。
  static const double sectionSpacing = 24;
}

/// 设置分项统一骨架：固定页头 + 统一样式的内容区。
///
/// 页头是设置页里标题的唯一来源（分项内部不再重复渲染大标题），
/// 且固定不随内容滚动；[scrollable] 只控制内容区是否由骨架提供滚动：
/// - 列表型分项传 false，由分项自身的 ListView 负责滚动；
/// - 表单型分项传 true，由骨架包一层 SingleChildScrollView。
class SettingsSectionScaffold extends StatelessWidget {
  const SettingsSectionScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions,
    this.scrollable = false,
  });

  final String title;
  final String? subtitle;

  /// 页头右侧操作区（可选），用于与列表无关的全局操作。
  final List<Widget>? actions;

  final bool scrollable;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final actions = this.actions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: SettingsLayout.headerPadding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: SettingsLayout.headerTitleSize,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: SettingsLayout.hintFontSize,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (actions != null && actions.isNotEmpty) ...[
                const SizedBox(width: 12),
                ...actions,
              ],
            ],
          ),
        ),
        const SizedBox(height: SettingsLayout.headerSpacing),
        Expanded(
          child: Padding(
            padding: SettingsLayout.contentPadding,
            child: scrollable ? SingleChildScrollView(child: child) : child,
          ),
        ),
      ],
    );
  }
}

/// 设置分项统一的顶部工具栏。
///
/// 分项的主要操作（新增 / 导入 / 保存）统一放在内容区顶部，
/// 各分项不再分别使用悬浮 FAB 或卡片内按钮。
class SettingsToolbar extends StatelessWidget {
  const SettingsToolbar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SettingsLayout.toolbarSpacing),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      ),
    );
  }
}

/// 分项内部区块标题（表单型分项使用）：标题 + 可选说明。
class SettingsSectionTitle extends StatelessWidget {
  const SettingsSectionTitle({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: SettingsLayout.sectionTitleSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: SettingsLayout.hintFontSize,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ],
    );
  }
}

/// 设置分项统一的空状态：图标 + 主提示 + 次要提示。
class SettingsEmptyState extends StatelessWidget {
  const SettingsEmptyState({
    super.key,
    required this.icon,
    required this.message,
    required this.hint,
  });

  final IconData icon;
  final String message;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(message),
          const SizedBox(height: 8),
          Text(
            hint,
            style: TextStyle(
              fontSize: SettingsLayout.hintFontSize,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }
}
