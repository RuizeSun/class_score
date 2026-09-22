import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../widgets/motion.dart';
import '../../widgets/pin_pad.dart';
import 'status_bar_layout.dart';

/// 解锁卡片顶边与状态栏底边之间的垂直间距（逻辑像素）。
const double unlockCardGap = 12;

/// 背景模糊的最大强度（sigma）。进场时由 0 渐变到该值，退场时反向回收。
const double _maxBlurSigma = 10;

/// 背景暗化程度（0~1）。与模糊强度同步渐变，避免背景突然变暗。
const double _dimOpacity = 0.10;

/// 以「整窗渐变模糊 + 状态栏胶囊保持清晰 + 卡片从右缘滑入」的形式显示解锁面板。
///
/// 模糊层是「原地」由清晰渐变为模糊的（模糊强度随进场进度增长、不做位移），
/// 只有卡片自身从窗口右缘外水平滑入，最终停在状态栏正下方、右缘与状态栏
/// 胶囊对齐。状态栏胶囊所在区域从模糊层中挖空，因此胶囊始终清晰，模糊背景
/// 与状态栏之间的衔接也顺着胶囊轮廓走，不会出现横向硬边。
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
    transitionDuration: AppMotion.resolve(context, AppMotion.medium),
    // 过渡全部由 [_UnlockOverlay] 自己驱动，这里原样透传 child。
    //
    // 不能让路由默认的 FadeTransition 包住整棵子树：BackdropFilter 的模糊
    // 不受祖先透明度影响，包一层透明度过渡的结果是「模糊瞬间以全强度出现」，
    // 再叠上位移就会看到模糊区域跟着卡片从右侧滑进来。改为把模糊强度与卡片
    // 位移分别绑定到进场进度后，背景才是原地逐渐变糊。
    transitionBuilder: (_, _, _, child) => child,
    pageBuilder: (_, animation, _) => _UnlockOverlay(animation: animation),
  );
}

/// 解锁浮层：整窗渐变模糊 + 状态栏胶囊保持清晰 + 卡片从右缘滑入。
///
/// 模糊层与卡片的动效分开驱动——背景只能「原地」变糊，只有卡片可以位移；
/// 两者若共用同一个变换，模糊区域就会跟着卡片一起平移。
class _UnlockOverlay extends StatefulWidget {
  const _UnlockOverlay({required this.animation});

  /// 弹窗路由的过渡进度：进场 0 → 1，退场 1 → 0。
  final Animation<double> animation;

  @override
  State<_UnlockOverlay> createState() => _UnlockOverlayState();
}

class _UnlockOverlayState extends State<_UnlockOverlay> {
  /// 卡片从窗口右缘外滑入所需的水平位移（逻辑像素）。
  ///
  /// 卡片宽度受 [UnlockPage.maxWidth] 限制，按最大宽度算即可保证起点完全
  /// 落在窗口右缘之外（卡片实际更窄时只会更靠外）。
  static const double _cardSlideDistance =
      StatusBarMetrics.inset + UnlockPage.maxWidth;

  /// 统一缓动后的进度：进场 easeOutCubic、退场 easeInCubic。
  late final CurvedAnimation _progress = CurvedAnimation(
    parent: widget.animation,
    curve: AppMotion.curve,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 背景：整窗模糊 + 轻微暗化，模糊强度与暗化程度都随进场进度从 0
        // 渐变到满值，因此是「原地逐渐变模糊」，不会跟着卡片平移。
        //
        // 注意：BackdropFilter 的模糊作用区域由最近的祖先裁剪（clip）决定，
        // 而不是由自身 bounds 决定——没有 clip 时模糊会作用于整屏（连状态栏
        // 一起糊掉）。这里用 ClipPath 把胶囊轮廓从整窗中挖空：裁剪边界正好
        // 落在胶囊自身的圆角轮廓上，既不会像水平直切那样切断胶囊底部与它的
        // 投影，模糊背景与状态栏之间也就没有突兀的硬边了。
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _progress,
            builder: (context, _) {
              final progress = _progress.value;
              return ClipPath(
                key: const ValueKey<String>('unlock-blur-clip'),
                clipper: const _StatusBarCutOutClipper(),
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: _maxBlurSigma * progress,
                    sigmaY: _maxBlurSigma * progress,
                  ),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: _dimOpacity * progress),
                  ),
                ),
              );
            },
          ),
        ),
        // 解锁卡片停在状态栏右下方，右缘与状态栏胶囊右缘对齐；
        // 只有卡片自身平移 + 淡入，背景层不参与。
        // （Windows 桌面窗口已置于工作区内，无需 SafeArea。）
        Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(
              top: StatusBarMetrics.bottom + unlockCardGap,
              right: StatusBarMetrics.inset,
            ),
            child: AnimatedBuilder(
              animation: _progress,
              child: const UnlockPage(),
              builder: (context, child) => Transform.translate(
                offset: Offset(
                  _cardSlideDistance * (1 - _progress.value),
                  0,
                ),
                child: FadeTransition(opacity: _progress, child: child),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 在整窗模糊层上挖掉状态栏胶囊所在区域，使其保持清晰。
///
/// evenOdd 填充 + 「整窗矩形 − 胶囊圆角矩形」= 整窗挖空胶囊。
class _StatusBarCutOutClipper extends CustomClipper<Path> {
  const _StatusBarCutOutClipper();

  @override
  Path getClip(Size size) => Path()
    ..fillType = PathFillType.evenOdd
    ..addRect(Offset.zero & size)
    ..addRRect(StatusBarMetrics.clarityRRect(size));

  @override
  bool shouldReclip(_StatusBarCutOutClipper oldClipper) => false;
}

/// 紧凑的解锁卡片内容。
///
/// 可由 [showUnlockOverlay] 作为弹出式面板使用；也保留了自身作为
/// [StatefulWidget] 的能力，便于单独测试或复用。
class UnlockPage extends StatefulWidget {
  /// 卡片最大宽度；进场动画的位移距离也以此计算。
  static const double maxWidth = 340;

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
        constraints: const BoxConstraints(maxWidth: UnlockPage.maxWidth),
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
