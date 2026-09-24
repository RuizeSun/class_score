import 'package:class_score/models/desktop_bar_style.dart';
import 'package:class_score/pages/settings/desktop_schedule_settings.dart';
import 'package:class_score/providers/desktop_schedule_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 只覆写「双外观开关」的 Provider：设置页用例要反复拨这个开关，
/// 而真实 setter 会写数据库（测试环境不应触碰磁盘）。
class _FakeDesktopScheduleProvider extends DesktopScheduleProvider {
  bool fakeForegroundEnabled = false;

  @override
  bool get foregroundEnabled => fakeForegroundEnabled;

  @override
  Future<void> setForegroundEnabled(bool value) async {
    fakeForegroundEnabled = value;
    notifyListeners();
  }
}

/// 直接渲染「桌面课表」设置分项（只依赖 DesktopScheduleProvider）。
Future<_FakeDesktopScheduleProvider> _pumpSettings(
  WidgetTester tester, {
  bool initiallyEnabled = false,
}) async {
  // 页面较长，给足高度避免行级溢出；列本身放在滚动容器里（与真实分项一致）。
  tester.view.physicalSize = const Size(1280, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final provider = _FakeDesktopScheduleProvider()
    ..fakeForegroundEnabled = initiallyEnabled;
  addTearDown(provider.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider<DesktopScheduleProvider>.value(
      value: provider,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: DesktopScheduleSettingsView()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return provider;
}

void main() {
  testWidgets('双外观开关默认关闭：前台组控件收起，桌面态分组照常显示', (tester) async {
    await _pumpSettings(tester);

    final switchTile = find.widgetWithText(
      SwitchListTile,
      '有程序在前台时使用另一套外观',
    );
    expect(switchTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);

    expect(find.text('外观（桌面态）'), findsOneWidget);
    expect(find.text('外观（有程序在前台时）'), findsOneWidget);

    // 开关关闭时前台组的控件完全不渲染
    expect(find.text('前台显示位置'), findsNothing);
    expect(find.text('前台窗口层级'), findsNothing);
    expect(find.text('前台鼠标穿透'), findsNothing);
    expect(find.text('前台不透明度'), findsNothing);
    expect(find.text('前台整体缩放'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('开启双外观：前台组出现（位置/层级/穿透/透明度/缩放），层级默认置顶', (tester) async {
    final provider = await _pumpSettings(tester);

    final switchTile = find.widgetWithText(
      SwitchListTile,
      '有程序在前台时使用另一套外观',
    );
    await tester.ensureVisible(switchTile);
    await tester.pumpAndSettle();
    await tester.tap(switchTile);
    await tester.pumpAndSettle();

    expect(provider.foregroundEnabled, isTrue);
    expect(tester.widget<SwitchListTile>(switchTile).value, isTrue);

    final fgPosition = find.widgetWithText(
      ChoiceTile<DesktopBarPosition>,
      '前台显示位置',
    );
    final fgLayer = find.widgetWithText(
      ChoiceTile<DesktopBarLayer>,
      '前台窗口层级',
    );
    expect(fgPosition, findsOneWidget);
    expect(fgLayer, findsOneWidget);
    expect(tester.widget<ChoiceTile<DesktopBarPosition>>(fgPosition).value,
        DesktopBarPosition.top);
    // 前台态默认置顶：避免被程序窗口挡住
    expect(tester.widget<ChoiceTile<DesktopBarLayer>>(fgLayer).value,
        DesktopBarLayer.topMost);
    expect(find.text('前台鼠标穿透'), findsOneWidget);
    expect(find.text('前台不透明度'), findsOneWidget);
    expect(find.text('前台整体缩放'), findsOneWidget);

    // 桌面态控件仍在，两套外观互不覆盖
    expect(
      find.widgetWithText(ChoiceTile<DesktopBarPosition>, '显示位置'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(ChoiceTile<DesktopBarLayer>, '窗口层级'),
      findsOneWidget,
    );

    // 关闭开关 → 前台组收起
    await tester.ensureVisible(switchTile);
    await tester.pumpAndSettle();
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(provider.foregroundEnabled, isFalse);
    expect(find.text('前台显示位置'), findsNothing);
    expect(find.text('前台整体缩放'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}