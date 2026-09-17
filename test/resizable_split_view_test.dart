import 'package:class_score/widgets/resizable_split_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 承载分栏的宿主：持有比例，模拟真实页面「比例由父级保存」的用法。
class _SplitHost extends StatefulWidget {
  const _SplitHost({this.initialRatio = 0.5});

  final double initialRatio;

  @override
  State<_SplitHost> createState() => _SplitHostState();
}

class _SplitHostState extends State<_SplitHost> {
  late double ratio = widget.initialRatio;

  /// onRatioChanged 的调用次数与最后一次的值。
  int changes = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ResizableSplitView(
          ratio: ratio,
          onRatioChanged: (value) {
            changes++;
            setState(() => ratio = value);
          },
          left: const SizedBox.expand(
            key: ValueKey('left_pane'),
            child: ColoredBox(color: Colors.red),
          ),
          right: const SizedBox.expand(
            key: ValueKey('right_pane'),
            child: ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
  }
}

double _paneWidth(WidgetTester tester) =>
    tester.getSize(find.byType(ResizableSplitView)).width -
    // 默认竖线命中区宽度
    12;

double _leftWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(const ValueKey('left_pane'))).width;

double _rightWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(const ValueKey('right_pane'))).width;

Future<void> _pump(WidgetTester tester, {double ratio = 0.5}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_SplitHost(initialRatio: ratio));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('按比例分栏，左右两栏同时可见且中间为一条竖线', (tester) async {
    await _pump(tester);

    final host = tester.state<_SplitHostState>(find.byType(_SplitHost));
    expect(host.ratio, 0.5);
    expect(_leftWidth(tester), closeTo(_paneWidth(tester) * 0.5, 0.5));
    expect(_rightWidth(tester), closeTo(_paneWidth(tester) * 0.5, 0.5));
    expect(find.byKey(ResizableSplitView.dividerKey), findsOneWidget);
    // 两栏撑满可用高度：内容较矮的一栏不应被垂直居中
    expect(tester.getSize(find.byKey(const ValueKey('left_pane'))).height, 800);
    expect(
      tester.getSize(find.byKey(const ValueKey('right_pane'))).height,
      800,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动竖线：实时改变两栏宽度并回传新比例', (tester) async {
    await _pump(tester);
    final paneWidth = _paneWidth(tester);
    final before = _leftWidth(tester);

    await tester.timedDrag(
      find.byKey(ResizableSplitView.dividerKey),
      const Offset(200, 0),
      const Duration(milliseconds: 200),
    );
    await tester.pumpAndSettle();

    final host = tester.state<_SplitHostState>(find.byType(_SplitHost));
    final after = _leftWidth(tester);
    expect(host.changes, 1, reason: '拖动结束应回传一次新比例');
    expect(after, greaterThan(before), reason: '向右拖动应加宽左栏');
    expect(
      host.ratio,
      closeTo(after / paneWidth, 0.01),
      reason: '回传的比例应与实际渲染宽度一致',
    );
    expect(
      _rightWidth(tester),
      closeTo(paneWidth - after, 0.5),
      reason: '两栏宽度之和应等于可用宽度',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动被最小宽度夹紧：任一栏都不会被拖没', (tester) async {
    await _pump(tester);
    final paneWidth = _paneWidth(tester);

    // 向左狂拖：应停在左栏最小宽度 360
    await tester.drag(
      find.byKey(ResizableSplitView.dividerKey),
      const Offset(-2000, 0),
    );
    await tester.pumpAndSettle();

    var host = tester.state<_SplitHostState>(find.byType(_SplitHost));
    expect(host.ratio, closeTo(360 / paneWidth, 0.01));
    expect(_leftWidth(tester), closeTo(360, 0.5));

    // 向右狂拖：应停在「总宽 - 右栏最小宽度 420」
    await tester.drag(
      find.byKey(ResizableSplitView.dividerKey),
      const Offset(2000, 0),
    );
    await tester.pumpAndSettle();

    host = tester.state<_SplitHostState>(find.byType(_SplitHost));
    expect(host.ratio, closeTo((paneWidth - 420) / paneWidth, 0.01));
    expect(_rightWidth(tester), closeTo(420, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('双击竖线复位为默认比例', (tester) async {
    await _pump(tester, ratio: 0.7);

    final divider = find.byKey(ResizableSplitView.dividerKey);
    await tester.tap(divider);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(divider);
    await tester.pumpAndSettle();

    final host = tester.state<_SplitHostState>(find.byType(_SplitHost));
    expect(host.ratio, ResizableSplitView.defaultRatio);
    expect(_leftWidth(tester), closeTo(_paneWidth(tester) * 0.5, 0.5));
    expect(tester.takeException(), isNull);
  });
}
