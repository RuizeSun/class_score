import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../widgets/pin_pad.dart';

/// 以「右上角浮动卡片 + 其余区域模糊」的形式显示解锁面板。
///
/// 返回值为 true 表示解锁成功，null / false 表示面板被关闭或解锁未完成。
Future<bool?> showUnlockOverlay(BuildContext context) {
  final auth = context.read<AuthProvider>();
  auth.clearError();

  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierLabel: '解锁',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => const _UnlockOverlay(),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.04, -0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _UnlockOverlay extends StatelessWidget {
  const _UnlockOverlay();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 其余区域：背景模糊 + 轻微暗化，突出右上角的解锁卡片。
        Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: Colors.black.withValues(alpha: 0.10)),
          ),
        ),
        // 解锁卡片固定在右上角，不再全屏占用窗口。
        Align(
          alignment: Alignment.topRight,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: const UnlockPage(),
            ),
          ),
        ),
      ],
    );
  }
}

/// 紧凑的解锁卡片内容。
///
/// 可由 [showUnlockOverlay] 作为弹出式面板使用；也保留了自身作为
/// [StatefulWidget] 的能力，便于单独测试或复用。
class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key});

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  String _pin = '';

  Future<void> _attemptUnlock() async {
    final auth = context.read<AuthProvider>();
    final success = await auth.unlock(_pin);
    if (!mounted) return;
    if (success) {
      // 以 true 关闭面板，与 [showUnlockOverlay] 的返回值约定保持一致。
      Navigator.of(context).maybePop(true);
    } else {
      setState(() => _pin = '');
    }
  }

  void _close() {
    context.read<AuthProvider>().clearError();
    // 未解锁即关闭：返回 false，便于调用方区分「解锁成功」与「主动关闭」。
    Navigator.of(context).maybePop(false);
  }

  void _onPinChanged(String value) {
    final auth = context.read<AuthProvider>();
    if (auth.errorMessage != null) {
      auth.clearError();
    }
    setState(() => _pin = value);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final useLongPin = auth.useLongPin;
    final scheme = Theme.of(context).colorScheme;

    return Material(
      elevation: 18,
      borderRadius: BorderRadius.circular(18),
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.lock_outline,
                      size: 20,
                      color: Colors.red.shade400,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '解锁',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          useLongPin ? '输入包含原始 PIN 的密码' : '输入 6 位 PIN 码',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: _close,
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (useLongPin)
                LongPinPad(
                  currentPin: _pin,
                  onPinChanged: _onPinChanged,
                  onConfirm: _attemptUnlock,
                )
              else
                PinPad(
                  currentPin: _pin,
                  onPinChanged: _onPinChanged,
                  onConfirm: _attemptUnlock,
                ),
              if (auth.errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  auth.errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
              if (useLongPin) ...[
                const SizedBox(height: 8),
                Text(
                  '也可以直接插入已绑定的 U 盘自动解锁',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
