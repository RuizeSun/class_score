import 'package:class_score/widgets/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 统一使用 Material 主题承载被测组件，并可覆盖「减少动态效果」开关。
Widget _host(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: Scaffold(body: child),
      ),
    ),
  );
}

/// 可切换 switchKey 的宿主：调用 [swap] 即触发一次内容切换，便于测试过渡过程。
class _SwitcherHost extends StatefulWidget {
  const _SwitcherHost({
    super.key,
    required this.buildChild,
    this.expand = false,
    this.alignment = Alignment.topCenter,
  });

  final Widget Function(String state) buildChild;
  final bool expand;
  final AlignmentGeometry alignment;

  @override
  State<_SwitcherHost> createState() => _SwitcherHostState();
}

class _SwitcherHostState extends State<_SwitcherHost> {
  String _state = 'a';

  /// 切换到新内容（触发过渡）。
  void swap(String next) => setState(() => _state = next);

  @override
  Widget build(BuildContext context) {
    return FadeThroughSwitcher(
      switchKey: _state,
      expand: widget.expand,
      alignment: widget.alignment,
      child: widget.buildChild(_state),
    );
  }
}

/// 可显示 / 收起内容的宿主，用于验证 [AppSizeTransition] 的尺寸过渡。
class _SizeHost extends StatefulWidget {
  const _SizeHost({super.key});

  static const double contentHeight = 60;

  @override
  State<_SizeHost> createState() => _SizeHostState();
}

class _SizeHostState extends State<_SizeHost> {
  bool _shown = true;

  void toggle() => setState(() => _shown = !_shown);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppSizeTransition(
          child: _shown
              ? const SizedBox(
                  key: ValueKey('内容'),
                  height: _SizeHost.contentHeight,
                  width: 100,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 取组件最近一层 [FadeTransition] 的不透明度，用于断言过渡进程。
double _fadeOpacity(WidgetTester tester, Finder finder) => tester
    .widget<FadeTransition>(
      find.ancestor(of: finder, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

void main() {
  testWidgets('FadeThroughSwitcher：旧内容先淡出、新内容后淡入，两层不叠影', (tester) async {
    final hostKey = GlobalKey<_SwitcherHostState>();
    await tester.pumpWidget(
      _host(
        _SwitcherHost(key: hostKey, buildChild: (state) => Text('内容$state')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('内容a'), findsOneWidget);
    expect(_fadeOpacity(tester, find.text('内容a')), 1);

    hostKey.currentState!.swap('b');
    await tester.pump();

    // 过渡中点：旧内容已淡出到不可见，新内容尚未进场（两层不重叠）
    await tester.pump(const Duration(milliseconds: 110));
    expect(_fadeOpacity(tester, find.text('内容a')), 0);
    expect(_fadeOpacity(tester, find.text('内容b')), 0);

    // 过渡结束：只剩新内容
    await tester.pumpAndSettle();
    expect(find.text('内容a'), findsNothing);
    expect(find.text('内容b'), findsOneWidget);
    expect(_fadeOpacity(tester, find.text('内容b')), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FadeThroughSwitcher：时长与曲线取统一动效常量，且淡出淡入不重叠', (tester) async {
    await tester.pumpWidget(
      _host(_SwitcherHost(buildChild: (state) => Text('内容$state'))),
    );
    await tester.pumpAndSettle();

    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    expect(switcher.duration, AppMotion.medium);
    expect(switcher.reverseDuration, AppMotion.medium);
    expect(switcher.switchInCurve, AppMotion.switchInCurve);
    expect(switcher.switchOutCurve, AppMotion.switchOutCurve);

    // 时间轴中点：旧内容已完全退场、新内容尚未出现（无交叉叠影）
    expect(AppMotion.switchOutCurve.transform(0.5), 0);
    expect(AppMotion.switchInCurve.transform(0.5), 0);
    expect(AppMotion.switchOutCurve.transform(1), 1);
    expect(AppMotion.switchInCurve.transform(1), 1);
  });

  testWidgets('FadeThroughSwitcher：系统开启减少动效时时长归零，直接切换', (tester) async {
    final hostKey = GlobalKey<_SwitcherHostState>();
    await tester.pumpWidget(
      _host(
        _SwitcherHost(key: hostKey, buildChild: (state) => Text('内容$state')),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration,
      Duration.zero,
      reason: '减少动效时不应再播放过渡',
    );

    hostKey.currentState!.swap('b');
    await tester.pumpAndSettle();
    expect(find.text('内容a'), findsNothing);
    expect(find.text('内容b'), findsOneWidget);
  });

  testWidgets('FadeThroughSwitcher：按 alignment 对齐，切换时内容不垂直居中', (tester) async {
    const containerKey = ValueKey('容器');
    await tester.pumpWidget(
      _host(
        SizedBox(
          key: containerKey,
          height: 300,
          width: 400,
          child: _SwitcherHost(
            alignment: Alignment.topLeft,
            buildChild: (state) =>
                SizedBox(key: ValueKey('块$state'), height: 40, width: 100),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('块a'))),
      tester.getTopLeft(find.byKey(containerKey)),
      reason: '滚动区内的内容块应按 alignment 贴边，而不是居中',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('FadeThroughSwitcher：expand 时子级铺满父级（紧约束）', (tester) async {
    const containerKey = ValueKey('容器');
    await tester.pumpWidget(
      _host(
        SizedBox(
          key: containerKey,
          height: 300,
          child: _SwitcherHost(
            expand: true,
            buildChild: (state) =>
                SizedBox(key: ValueKey('块$state'), width: 50),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byKey(const ValueKey('块a'))).height, 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AppSizeTransition：内容收起时高度平滑过渡而非瞬间塌陷', (tester) async {
    final hostKey = GlobalKey<_SizeHostState>();
    await tester.pumpWidget(_host(_SizeHost(key: hostKey)));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('内容'))).height,
      _SizeHost.contentHeight,
    );

    hostKey.currentState!.toggle();
    // 过渡中：内容已移除，但容器高度仍在收缩（尚未归零）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    final midHeight = tester.getSize(find.byType(AppSizeTransition)).height;
    expect(midHeight, greaterThan(0));
    expect(midHeight, lessThan(_SizeHost.contentHeight));

    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AppSizeTransition)).height, 0);
    expect(tester.takeException(), isNull);
  });
}
