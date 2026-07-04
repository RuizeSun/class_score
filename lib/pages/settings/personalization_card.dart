import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/personalization_provider.dart';

/// Personalization settings card for use in SettingsHubPage.
class PersonalizationCard extends StatelessWidget {
  const PersonalizationCard({super.key});

  @override
  Widget build(BuildContext context) {
    final personalization = context.watch<PersonalizationProvider>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '个性化',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // ---- 主题色选择 ----
            const Text(
              '主题色',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              '选择一个种子色，应用将根据 Material 3 设计风格自动生成配色方案',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
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
                          ? const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),

            const Divider(height: 32),

            // ---- 窗口行为开关 ----
            const Text(
              '窗口行为',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              '控制应用在锁定状态下的窗口操作行为',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
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
              onChanged: (value) =>
                  personalization.setAllowCloseWhenLocked(value),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }
}
