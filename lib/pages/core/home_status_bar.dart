import 'package:flutter/material.dart';

import 'status_bar_layout.dart';

/// 主页顶部状态栏（胶囊条）。
///
/// 单独抽成组件的两个原因：
/// 1. 胶囊是一块圆角容器，按钮的「悬停高亮 / 水波纹」却是按钮自身的
///    Material 绘制的一层叠层（不受祖先装饰影响）：按钮贴在胶囊右端时，
///    叠层的方角会落在胶囊的半圆轮廓之外。这里让按钮外观直接取
///    [StadiumBorder]（胶囊形），叠层便与胶囊右端的半圆重合；同时在胶囊上
///    设置 [Clip.antiAlias]，作为布局再变化时的兜底裁剪。
/// 2. 抽出来后可以脱离 HomePage 的窗口初始化逻辑（window_manager 等）
///    单独做布局测试。
class HomeStatusBar extends StatelessWidget {
  const HomeStatusBar({
    super.key,
    required this.isUnlocked,
    required this.currentCourseName,
    required this.onUnlock,
    required this.onShowUsbKey,
    required this.onLock,
  });

  /// 是否已解锁：决定胶囊配色与右侧按钮组。
  final bool isUnlocked;

  /// 当前课程名；为空时显示「无」。
  final String? currentCourseName;

  /// 点击「解锁」：打开解锁浮层。
  final VoidCallback onUnlock;

  /// 点击「密钥」：打开 USB 密钥页面。
  final VoidCallback onShowUsbKey;

  /// 点击「上锁」：立即重新上锁。
  final VoidCallback onLock;

  /// 右侧文字按钮的统一外观。
  ///
  /// [StadiumBorder] 让悬停高亮 / 水波纹本身就是「胶囊（跑道）形」，
  /// 与状态栏胶囊保持同一种语言：按钮被 Row 拉伸到与胶囊等高、右缘又与
  /// 胶囊右缘对齐，因此半径 = 高度 / 2 的跑道形右端正好与胶囊右端的
  /// 半圆重合，悬停时看起来就是胶囊右端被点亮，而不是一块贴上去的方角。
  static ButtonStyle _actionStyle(Color color) => TextButton.styleFrom(
    foregroundColor: color,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    shape: const StadiumBorder(),
  );

  @override
  Widget build(BuildContext context) {
    final accent = isUnlocked ? Colors.green : Colors.red;

    return Padding(
      padding: const EdgeInsets.all(StatusBarMetrics.inset),
      child: Container(
        width: double.infinity,
        height: StatusBarMetrics.height,
        decoration: BoxDecoration(
          color: isUnlocked ? Colors.green.shade50 : Colors.red.shade50,
          borderRadius: BorderRadius.circular(StatusBarMetrics.radius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        // 兜底裁剪：按钮的悬停高亮 / 水波纹由按钮自身的 Material 绘制，
        // 形状虽已是胶囊（见 [_actionStyle] 的 [StadiumBorder]），这里仍把
        // 子组件整体裁进胶囊轮廓——万一以后按钮更宽 / 更高或贴边方式改变，
        // 叠层也不会从圆角处溢出。
        clipBehavior: Clip.antiAlias,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Row(
                children: [
                  Icon(
                    isUnlocked ? Icons.lock_open : Icons.lock,
                    size: 16,
                    color: accent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isUnlocked ? '已解锁' : '已锁定',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Center(
                    child: Container(
                      width: 1,
                      height: 16,
                      color: Colors.grey.withValues(alpha: 0.3),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(Icons.school, size: 16, color: Colors.blue.shade700),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '课程：${currentCourseName ?? '无'}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.blue.shade700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (!isUnlocked)
              TextButton.icon(
                onPressed: onUnlock,
                icon: const Icon(Icons.lock_open, size: 14),
                label: const Text('解锁', style: TextStyle(fontSize: 12)),
                style: _actionStyle(Colors.red),
              )
            else ...[
              TextButton.icon(
                onPressed: onShowUsbKey,
                icon: const Icon(Icons.usb, size: 14),
                label: const Text('密钥', style: TextStyle(fontSize: 12)),
                style: _actionStyle(Colors.indigo),
              ),
              TextButton.icon(
                onPressed: onLock,
                icon: const Icon(Icons.lock, size: 14),
                label: const Text('上锁', style: TextStyle(fontSize: 12)),
                style: _actionStyle(Colors.orange),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
