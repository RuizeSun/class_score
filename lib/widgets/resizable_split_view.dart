import 'package:flutter/material.dart';

/// 平板式左右分栏：两栏同时可见，中间一条可拖拽的竖线调整显示比例。
///
/// 比例（左栏占比）由调用方持有，可持久化到设置；组件只负责：
/// - 按 [minLeftWidth] / [minRightWidth] 夹紧比例，避免任一栏被拖没；
/// - 拖动过程用内部临时比例渲染（不每帧写回设置），松手后通过
///   [onRatioChanged] 回传最终比例；
/// - 双击竖线复位为 [defaultRatio]。
class ResizableSplitView extends StatefulWidget {
  const ResizableSplitView({
    super.key,
    required this.left,
    required this.right,
    required this.ratio,
    required this.onRatioChanged,
    this.minLeftWidth = 360,
    this.minRightWidth = 420,
    this.dividerHitWidth = 12,
  });

  /// 左栏占比（0~1）。
  final double ratio;

  /// 拖拽结束后回传的新占比（已夹紧）。
  final ValueChanged<double> onRatioChanged;

  /// 左栏最小宽度（逻辑像素）。
  final double minLeftWidth;

  /// 右栏最小宽度（逻辑像素）。
  final double minRightWidth;

  /// 竖线命中区宽度；视觉上仍是一条细线。
  final double dividerHitWidth;

  /// 竖线命中区的 Key（便于测试定位与拖动）。
  static const ValueKey<String> dividerKey = ValueKey(
    'resizable_split_view_divider',
  );

  /// 双击竖线复位到的占比。
  static const double defaultRatio = 0.5;

  final Widget left;
  final Widget right;

  @override
  State<ResizableSplitView> createState() => _ResizableSplitViewState();
}

class _ResizableSplitViewState extends State<ResizableSplitView> {
  /// 拖动中的临时比例；为空表示未拖动。
  ///
  /// 松手后不立即清空：比例由父级（可能异步写库后）回传，若立刻清空会出现
  /// 「先闪回旧比例、再跳到新比例」的一帧回跳。等父级把新比例传进来
  /// （见 [didUpdateWidget]）再清空。
  double? _dragRatio;

  bool _hovering = false;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant ResizableSplitView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragRatio != null && widget.ratio != oldWidget.ratio) {
      _dragRatio = null;
    }
  }

  /// 按最小宽度约束夹紧比例。
  double _clampRatio(double ratio, double paneWidth) {
    final maxLeft = paneWidth - widget.minRightWidth;
    final minLeft = widget.minLeftWidth;
    // 空间不足（窗口被缩得比两栏最小值还小）时均分，保证不溢出。
    if (maxLeft <= minLeft) return ResizableSplitView.defaultRatio;
    return (paneWidth * ratio).clamp(minLeft, maxLeft) / paneWidth;
  }

  void _onDragUpdate(DragUpdateDetails details, double paneWidth) {
    final current = _clampRatio(_dragRatio ?? widget.ratio, paneWidth);
    setState(() {
      _dragRatio = current + details.delta.dx / paneWidth;
    });
  }

  void _onDragEnd(double paneWidth) {
    final ratio = _clampRatio(_dragRatio ?? widget.ratio, paneWidth);
    setState(() => _dragging = false);
    if (ratio != widget.ratio) widget.onRatioChanged(ratio);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final paneWidth = (constraints.maxWidth - widget.dividerHitWidth).clamp(
          1.0,
          100000.0,
        );
        final ratio = _clampRatio(_dragRatio ?? widget.ratio, paneWidth);
        final leftWidth = paneWidth * ratio;

        return Row(
          // 两栏都撑满可用高度：否则内容较矮的一栏（如榜单）会被 Row 垂直居中
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: leftWidth, child: widget.left),
            _buildDivider(paneWidth),
            SizedBox(width: paneWidth - leftWidth, child: widget.right),
          ],
        );
      },
    );
  }

  Widget _buildDivider(double paneWidth) {
    final scheme = Theme.of(context).colorScheme;
    final active = _hovering || _dragging;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => widget.onRatioChanged(
          _clampRatio(ResizableSplitView.defaultRatio, paneWidth),
        ),
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (details) => _onDragUpdate(details, paneWidth),
        onHorizontalDragEnd: (_) => _onDragEnd(paneWidth),
        onHorizontalDragCancel: () => setState(() => _dragging = false),
        child: SizedBox(
          key: ResizableSplitView.dividerKey,
          width: widget.dividerHitWidth,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: active ? 3 : 1,
              decoration: BoxDecoration(
                color: active ? scheme.primary : scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
