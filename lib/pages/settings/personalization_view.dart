import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/personalization_provider.dart';
import 'settings_common.dart';

/// 个性化设置分项（无卡片，可嵌入 SettingsHubPage）。
class PersonalizationView extends StatelessWidget {
  const PersonalizationView({super.key});

  @override
  Widget build(BuildContext context) {
    final personalization = context.watch<PersonalizationProvider>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- 主题色选择 ----
        const SettingsSectionTitle(
          title: '主题色',
          subtitle: '选择一个种子色，应用将根据 Material 3 设计风格自动生成配色方案',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: PersonalizationProvider.availableColors.map((entry) {
            final color = entry['color'] as Color;
            final name = entry['name'] as String;
            final isSelected =
                color.toARGB32() == personalization.seedColor.toARGB32();
            return GestureDetector(
              onTap: () => personalization.setSeedColor(color),
              child: Tooltip(
                message: name,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? Colors.black87 : Colors.grey,
                      width: isSelected ? 3 : 1,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: color.withValues(alpha: 0.4),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 20)
                      : null,
                ),
              ),
            );
          }).toList(),
        ),

        const SizedBox(height: SettingsLayout.sectionSpacing),
        const Divider(height: 1),

        // ---- 窗口行为开关 ----
        const SizedBox(height: SettingsLayout.sectionSpacing),
        const SettingsSectionTitle(
          title: '窗口行为',
          subtitle: '控制应用在锁定状态下的窗口操作行为',
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          secondary: const Icon(Icons.minimize),
          title: const Text('未解锁时允许最小化窗口'),
          subtitle: const Text('开启后，即使应用处于锁定状态也可以最小化窗口'),
          value: personalization.allowMinimizeWhenLocked,
          onChanged: (value) =>
              personalization.setAllowMinimizeWhenLocked(value),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.close),
          title: const Text('未解锁时允许关闭窗口'),
          subtitle: const Text('开启后，即使应用处于锁定状态也可以直接关闭窗口'),
          value: personalization.allowCloseWhenLocked,
          onChanged: (value) => personalization.setAllowCloseWhenLocked(value),
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }
}
