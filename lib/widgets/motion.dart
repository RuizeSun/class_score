import 'package:flutter/material.dart';

/// 全应用统一的过渡动效节奏。
///
/// 各处的切换（查询页两栏内容、设置页分项、加载态、启动入口）此前都是瞬时
/// 替换，快慢与曲线各不相同；这里集中定义时长与曲线，接入点只引用常量，
/// 避免散落的魔法数字导致整体节奏不一致。
class AppMotion {
  AppMotion._();

  /// 快速过渡：小范围状态切换与列表整体刷新
  /// （联动提示条、批量操作栏、记录列表换筛选）。
  static const Duration fast = Duration(milliseconds: 150);

  /// 标准过渡：页面内的内容块语义切换（榜单换维度、设置页换分项）。
  static const Duration medium = Duration(milliseconds: 220);

  /// 较慢过渡：整屏级切换（启动入口、解锁后进入主页）。
  static const Duration slow = Duration(milliseconds: 320);

  /// 统一缓动曲线：进场略快、收尾平滑，既不拖沓也不突兀。
  static const Curve curve = Curves.easeOutCubic;

  /// 新内容淡入曲线：过渡后半段出现。
  static const Curve switchInCurve = Interval(0.5, 1.0, curve: Curves.easeOut);

  /// 旧内容淡出曲线：过渡前半段退场。
  ///
  /// 这里刻意与 [switchInCurve] 共用同一个 [Interval]：它作为
  /// [AnimatedSwitcher] 的 reverseCurve 描述的是「旧内容自身」的进度，
  /// 反向播放时 1 → 0.5 恰好落在过渡的前半段，于是新旧内容在时间轴上
  /// 首尾相接、互不重叠（fade through）。
  static const Curve switchOutCurve = Interval(0.5, 1.0, curve: Curves.easeIn);

  /// 应用时长：系统开启「减少动态效果」时归零，改为直接切换。
  static Duration resolve(BuildContext context, Duration duration) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
      ? Duration.zero
      : duration;
}

/// 内容块切换过渡：旧内容先淡出、新内容后淡入（fade through）。
///
/// 触发方式二选一：给 [switchKey] 换新值，或直接给 [child] 换 key。
///
/// 为什么是「先出后进」而不是交叉淡入：
/// 这里切换的多是同类控件（榜单换维度、列表换筛选、图表换目标），两块内容
/// 外观几乎一致；交叉淡入会让两层近似内容在过渡中叠影，看起来像内容整体
/// 抖了一下。改成旧内容在前半段退场、新内容在后半段进场后，两层互不重叠，
/// 也就没有叠影；同时过渡不做位移——位移会让两层错位，叠影感更强。
///
/// 另外显式控制过渡容器：滚动区里若用 [AnimatedSwitcher] 默认的
/// 「居中 + 松约束」Stack，内容会在切换瞬间跳到垂直中间。
class FadeThroughSwitcher extends StatelessWidget {
  const FadeThroughSwitcher({
    super.key,
    required this.child,
    this.switchKey,
    this.duration,
    this.alignment = Alignment.topCenter,
    this.expand = false,
  });

  /// 参与切换的内容。
  final Widget child;

  /// 切换标识：值变化即触发过渡；为 null 时以 [child] 自身的 key 为准。
  final Object? switchKey;

  /// 过渡时长；默认 [AppMotion.medium]，系统减少动效时自动归零。
  final Duration? duration;

  /// 过渡容器的对齐方式（默认顶部居中，适合滚动区内的内容块）。
  final AlignmentGeometry alignment;

  /// 是否用紧约束铺满父级：父级高度确定（如分屏右栏、整屏页面）时传 true。
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final effectiveDuration = AppMotion.resolve(
      context,
      duration ?? AppMotion.medium,
    );

    return AnimatedSwitcher(
      duration: effectiveDuration,
      reverseDuration: effectiveDuration,
      switchInCurve: AppMotion.switchInCurve,
      switchOutCurve: AppMotion.switchOutCurve,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        fit: expand ? StackFit.expand : StackFit.loose,
        children: [
          // 淡出中的旧内容不再响应点击，避免过渡期间误触已失效的控件
          for (final child in previousChildren) IgnorePointer(child: child),
          ?currentChild,
        ],
      ),
      // 默认 transitionBuilder 即 FadeTransition，这里只做透明度过渡
      child: switchKey == null
          ? child
          : KeyedSubtree(key: ValueKey<Object?>(switchKey), child: child),
    );
  }
}

/// 尺寸过渡容器：用于「出现 / 消失」型内容（联动提示、批量操作栏）。
///
/// [AnimatedSize] 自带的曲线与时长与应用其它过渡不一致，这里统一为 [AppMotion]；
/// 内容本身的淡入淡出由内层 [FadeThroughSwitcher] 负责，两者配合使用。
class AppSizeTransition extends StatelessWidget {
  const AppSizeTransition({
    super.key,
    required this.child,
    this.alignment = Alignment.topCenter,
    this.duration,
  });

  final Widget child;

  /// 尺寸变化时的对齐方式（顶部对齐时表现为向下展开）。
  final AlignmentGeometry alignment;

  /// 过渡时长；默认 [AppMotion.fast]，系统减少动效时自动归零。
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      alignment: alignment,
      duration: AppMotion.resolve(context, duration ?? AppMotion.fast),
      curve: AppMotion.curve,
      child: child,
    );
  }
}
