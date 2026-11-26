import 'package:flutter/material.dart';

import 'motion.dart';

/// 统一的「正在计算」表达。
///
/// 全应用此前各写一套：有的页面转圈、有的页面什么都不显示（直接渲染空列表，
/// 看起来像「没数据」）、有的只是把按钮变灰。这里收拢成三种粒度，让「等待」
/// 在任何页面都长得一样：
///
/// - [PageLoadingView]：整块内容首次加载（还不知道有没有数据）。
/// - [InlineLoadingBar]：已有内容、正在刷新（保留旧内容，顶部一条细进度条）。
/// - [runBusy]：一次性操作（导入 / 导出 / 重置 / 提交），期间挡住重复点击。
///
/// 动效时长统一取 [AppMotion]，系统开启「减少动态效果」时自动退化。

/// 首次加载占位：居中转圈 + 可选说明文字。
class PageLoadingView extends StatelessWidget {
  const PageLoadingView({super.key, this.label, this.minHeight});

  /// 说明文字（如「正在读取评分记录…」）。为空时只显示转圈。
  final String? label;

  /// 占据的最小高度：放在分栏/可滚动区里时避免内容跳动。
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.6),
        ),
        if (label != null) ...[
          const SizedBox(height: 12),
          Text(
            label!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );

    return SizedBox(
      height: minHeight,
      child: Center(
        child: Semantics(
          label: label ?? '正在加载',
          liveRegion: true,
          child: content,
        ),
      ),
    );
  }
}

/// 刷新期间的细进度条：**保留已有内容**，只在顶部加一条不确定进度。
///
/// 用 [LinearProgressIndicator] 的 minHeight=2、不占布局高度（Stack 覆盖），
/// 因此刷新时不会把下面的内容顶下去。
///
/// 注意：不加载时**完全不构建**进度条，而不是把它透明度调成 0。
/// 不确定进度的 `LinearProgressIndicator`（没有 value）会永久调度动画帧，
/// 即使完全透明也照跑——那是永不停止的每帧重绘，正是要消除的掉帧来源。
class InlineLoadingBar extends StatelessWidget {
  const InlineLoadingBar({
    super.key,
    required this.loading,
    required this.child,
  });

  final bool loading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!loading) return child;
    return Stack(
      children: [
        child,
        const Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(child: LinearProgressIndicator(minHeight: 2)),
        ),
      ],
    );
  }
}

/// 模态忙碌遮罩：一次性操作执行期间显示转圈并挡住点击。
///
/// 只做视觉与输入拦截，不负责生命周期；推荐直接用 [runBusy]。
class BusyOverlay extends StatelessWidget {
  const BusyOverlay({super.key, required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.28),
      child: Center(
        child: Card(
          elevation: 6,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                if (message != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    message!,
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
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

/// 执行一次性耗时操作，并在其期间显示 [BusyOverlay]。
///
/// 用法：
/// ```dart
/// await runBusy(context, () => BackupService.instance.exportToJson(),
///     message: '正在导出数据库…');
/// ```
///
/// 实现要点：
/// - 遮罩挂在**根 Overlay** 上，因此即使操作关掉了对话框也不会消失；
/// - `await` 之后只按 `OverlayEntry.mounted` 判断，不碰可能已失效的 context；
/// - 异常照常向上抛（调用方原有的 try/catch 不用改）。
Future<T> runBusy<T>(
  BuildContext context,
  Future<T> Function() task, {
  String? message,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => BusyOverlay(message: message),
  );
  overlay.insert(entry);
  try {
    return await task();
  } finally {
    if (entry.mounted) entry.remove();
  }
}

/// 表格/图表类页面的通用加载四件套。
///
/// 现在 dashboard 与 analysis 各写了一份集合了 `_loading` / `_hasLoadedOnce` /
/// `_loadGeneration` 的逻辑，statistics 则一份都没有。抽出来统一：
///
/// - [loading]：是否有请求在飞；
/// - [hasLoadedOnce]：是否成功跑过一次（决定「首次转圈」还是「保留内容刷新」）；
/// - [generation]：并发保护，只有最新一次请求允许写回。
///
/// 用法（State 里混入）：
/// ```dart
/// class _XState extends State<X> with LoadableStateMixin {
///   Future<void> _load() => runLoad(() async {
///     final data = await fetch();
///     if (!owns(latest)) return;   // 用 beginLoad() 返回的令牌判断
///   });
/// }
/// ```
mixin LoadableStateMixin<T extends StatefulWidget> on State<T> {
  bool _loading = false;
  bool _hasLoadedOnce = false;
  int _generation = 0;

  /// 是否有请求在飞。
  bool get isLoading => _loading;

  /// 是否已成功完成过至少一次加载。
  bool get hasLoadedOnce => _hasLoadedOnce;

  /// 开始一次加载：返回本次请求的序号（用于并发保护）。
  ///
  /// 注意：这里只递增序号并置 loading，**不**主动 setState——调用方通常紧接着
  /// 就会自己 `setState`，避免一帧里连发两次重建。
  int beginLoad() {
    _loading = true;
    return ++_generation;
  }

  /// 本次请求是否仍是最新的（旧请求的结果不允许写回 UI）。
  bool isLatest(int token) => token == _generation;

  /// 结束一次加载（无论成功或失败都要调用，否则转圈不会停）。
  void endLoad() {
    _loading = false;
    _hasLoadedOnce = true;
  }

  /// 出错时收掉加载态但**不**标记「已加载」：让下次进入仍显示首次占位。
  void failLoad() {
    _loading = false;
  }
}

/// 给内容块加淡入淡出的加载态外壳。
///
/// 首次加载显示 [PageLoadingView]，之后刷新保留内容并在顶部显示细进度条。
class LoadableContent extends StatelessWidget {
  const LoadableContent({
    super.key,
    required this.loading,
    required this.hasLoadedOnce,
    required this.child,
    this.loadingLabel,
    this.minHeight,
  });

  final bool loading;

  /// 是否已经加载过至少一次。
  final bool hasLoadedOnce;

  final Widget child;

  final String? loadingLabel;

  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    final showInitial = loading && !hasLoadedOnce;
    return FadeThroughSwitcher(
      expand: true,
      switchKey: showInitial ? 'loading' : 'content',
      child: showInitial
          ? PageLoadingView(label: loadingLabel, minHeight: minHeight)
          : InlineLoadingBar(loading: loading, child: child),
    );
  }
}
