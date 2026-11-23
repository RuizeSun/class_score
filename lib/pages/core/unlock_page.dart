import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/personalization_provider.dart';
import '../../widgets/glass_buttons.dart';
import '../../widgets/motion.dart';
import '../../widgets/pin_pad.dart';
import 'status_bar_layout.dart';

/// 解锁卡片顶边与状态栏底边之间的垂直间距（逻辑像素）。
const double unlockCardGap = 12;

/// 背景模糊的最大强度（sigma）。进场时由 0 渐变到该值，退场时反向回收。
const double unlockBlurSigma = 3;

/// 背景暗化程度（0~1）。与模糊强度同步渐变，避免背景突然变暗。
const double unlockDimOpacity = 0.12;

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
    // 不能让路由默认的 FadeTransition 包住整棵子树：卡片是玻璃容器，它的
    // BackdropFilter 只有在「下面已经画好了真实内容」时才取得对。祖先一旦
    // 有透明度层（FadeTransition / Opacity 会 push 一层临时缓冲），玻璃取到
    // 的 backdrop 就只剩这层空缓冲，于是卡片滑入期间一点不糊、淡入结束才
    // 突然变糊；再叠上位移还会看到模糊区域跟着卡片从右侧滑进来。
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

  /// 背景模糊 / 压暗用的进度：进场前 35% 就到位，卡片滑入期间背景已经是虚化的。
  late final CurvedAnimation _blurProgress = CurvedAnimation(
    parent: widget.animation,
    curve: const Interval(0, 0.35, curve: Curves.easeOut),
    reverseCurve: Curves.easeIn,
  );

  @override
  void dispose() {
    _blurProgress.dispose();
    _progress.dispose();
    super.dispose();
  }

  /// 点击模糊背景关闭面板。
  ///
  /// 与卡片右上角「关闭」按钮走同一条路径：先清掉残留的错误提示，再以
  /// false 关闭，调用方据此区分「解锁成功」与「主动关闭」。
  void _dismiss() {
    context.read<AuthProvider>().clearError();
    Navigator.of(context).maybePop(false);
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
            animation: _blurProgress,
            builder: (context, _) {
              final progress = _blurProgress.value;
              return ClipPath(
                key: const ValueKey<String>('unlock-blur-clip'),
                clipper: const _StatusBarCutOutClipper(),
                // 手势检测器必须放在 ClipPath 之内：RenderClipPath.hitTest
                // 会先判断点是否落在裁剪路径里，放在里面才能让「被挖空的
                // 状态栏区域」不参与命中测试——点状态栏胶囊既不会关闭面板，
                // 也不会被本层吞掉（会落到下方的模态遮罩上）。
                child: GestureDetector(
                  key: const ValueKey<String>('unlock-blur-dismiss'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _dismiss,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: unlockBlurSigma * progress,
                      sigmaY: unlockBlurSigma * progress,
                    ),
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: unlockDimOpacity * progress,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // 解锁卡片停在状态栏右下方，右缘与状态栏胶囊右缘对齐；
        // 只有卡片自身平移，背景层不参与。
        // （Windows 桌面窗口已置于工作区内，无需 SafeArea。）
        //
        // 这里刻意不给卡片套 FadeTransition：卡片是玻璃容器，它的
        // BackdropFilter 取的是「已经画在下面的内容」。祖先一旦有透明度层
        // （Opacity/FadeTransition 会 push 一个临时 buffer / saveLayer），
        // 玻璃的 backdrop 就只剩这个空 buffer，模糊等于没做——表现出来就是
        // 卡片滑入时背景清晰、淡入结束后才突然变糊。卡片起点本来就在窗口
        // 右缘之外，不需要靠淡入来遮住出场。
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
                offset: Offset(_cardSlideDistance * (1 - _progress.value), 0),
                child: child,
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
    final glassQuality = context.watch<PersonalizationProvider>().glassQuality;
    final useLongPin = auth.useLongPin;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: UnlockPage.maxWidth),
      child: Listener(
        // 玻璃容器自身不参与命中测试：卡片空白处也要吞掉点击，不能穿透到
        // 背景模糊层（那会把「点卡片」误判成「点背景关闭」）。
        behavior: HitTestBehavior.opaque,
        // GlassContainer 不是 Material，不会像 Material 那样给子树提供
        // DefaultTextStyle。缺了它，卡片里的 Text 会落回 MaterialApp 的兜底
        // 样式（红色、monospace、双层黄色下划线，见 _errorTextStyle），
        // 文字下方就会多出两条黄线。这里显式补上 Material 正文样式。
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.bodyMedium!,
          child: GlassContainer(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            shape: const LiquidRoundedSuperellipse(borderRadius: 24),
            useOwnLayer: true,
            quality: glassQuality,
            glowIntensity: 0.6,
            settings: LiquidGlassSettings(
              glassColor: Colors.white.withValues(alpha: 0.26),
              thickness: 24,
              blur: 12,
              frost: 6,
              frostOpacity: 0.35,
              chromaticAberration: 0.08,
              rimShade: 0.7,
              rimLight: 1.2,
              glowIntensity: 0.9,
              shadowElevation: 0.6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.red.shade500,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.red.shade400.withValues(alpha: 0.5),
                            blurRadius: 16,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.lock_outline,
                        size: 22,
                        color: Colors.white,
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
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            useLongPin ? '输入包含原始 PIN 的密码' : '输入 6 位 PIN 码',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GlassIconAction(
                      tooltip: '关闭',
                      size: 34,
                      iconSize: 20,
                      onPressed: _close,
                      foregroundColor: Colors.black54,
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
                    glassKeys: true,
                  )
                else
                  PinPad(
                    currentPin: _pin,
                    onPinChanged: _onPinChanged,
                    onConfirm: _attemptUnlock,
                    glassKeys: true,
                  ),
                if (auth.errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    auth.errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                    ),
                  ),
                ],
                if (useLongPin) ...[
                  const SizedBox(height: 8),
                  Text(
                    '也可以直接插入已绑定的 U 盘自动解锁',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
