import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/score_provider.dart';

class PeriodManagementView extends StatelessWidget {
  const PeriodManagementView({super.key});

  Future<void> _switchToNextPeriod(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换到下一周期'),
        content: const Text(
          '即将切换到下一评分周期，当前周期的评分记录将保留，但下一周期的评分记录将被清空。\n\n确认切换吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认切换'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await context.read<ScoreProvider>().switchToNextPeriod();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已切换到下一评分周期'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _switchToPreviousPeriod(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换到上一周期'),
        content: const Text('即将切换到上一评分周期，可以查看上一周期的评分记录。\n\n确认切换吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认切换'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await context.read<ScoreProvider>().switchToPreviousPeriod();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已切换到上一评分周期'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scoreProvider = context.watch<ScoreProvider>();
    final auth = context.watch<AuthProvider>();
    final currentPeriod = scoreProvider.currentPeriod;
    final canGoPrevious = currentPeriod > 1;
    final isUnlocked = auth.isUnlocked;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.calendar_today,
                  size: 28,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                const Text(
                  '评分周期管理',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 切换到上一周期按钮
                IconButton.filled(
                  onPressed: isUnlocked && canGoPrevious
                      ? () => _switchToPreviousPeriod(context)
                      : null,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '切换到上一周期',
                ),
                const SizedBox(width: 16),
                // 当前周期显示
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '第 $currentPeriod 期',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // 切换到下一周期按钮
                IconButton.filled(
                  onPressed: isUnlocked
                      ? () => _switchToNextPeriod(context)
                      : null,
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: '切换到下一周期',
                ),
              ],
            ),
            const SizedBox(height: 24),
            Center(
              child: Text(
                '切换到下一周期后，新周期的评分记录将从 0 开始',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
