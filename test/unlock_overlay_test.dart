import 'package:class_score/pages/core/unlock_page.dart';
import 'package:class_score/providers/auth_provider.dart';
import 'package:class_score/widgets/pin_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 测试用的正确 PIN。
const String _correctPin = '123456';

/// 仅内存的 AuthProvider：不访问数据库，PIN 校验结果由测试直接给定。
class _FakeAuthProvider extends AuthProvider {
  String? _error;

  @override
  String? get errorMessage => _error;

  @override
  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  Future<bool> unlock(String pin) async {
    if (pin == _correctPin) {
      _error = null;
      notifyListeners();
      return true;
    }
    _error = 'PIN 码错误';
    notifyListeners();
    return false;
  }
}

/// 宿主页：一个按钮打开解锁面板，返回值收集到 [results]。
Widget _buildHost(AuthProvider auth, List<Future<bool?>> results) {
  return ChangeNotifierProvider<AuthProvider>.value(
    value: auth,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => results.add(showUnlockOverlay(context)),
              child: const Text('打开解锁面板'),
            ),
          ),
        ),
      ),
    ),
  );
}

void _useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, '打开解锁面板'));
  await tester.pumpAndSettle();
}

/// 逐位点按数字键盘：第 6 位输入完成后键盘会自动确认。
Future<void> _enterPin(WidgetTester tester, String pin) async {
  for (final digit in pin.split('')) {
    await tester.tap(find.widgetWithText(TextButton, digit));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('解锁面板为右上角浮动卡片，其余区域模糊（不再全屏占用）', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHost(_FakeAuthProvider(), []));
    await _openPanel(tester);

    // 其余区域：整窗模糊层（覆盖整个窗口，而不是覆盖卡片）
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.getSize(find.byType(BackdropFilter)), const Size(1280, 800));

    // 卡片：尺寸紧凑 + 贴右上角，说明是浮动面板而非整屏路由
    final card = find.byType(UnlockPage);
    expect(card, findsOneWidget);
    expect(find.byType(PinPad), findsOneWidget);
    final cardSize = tester.getSize(card);
    expect(cardSize.width, lessThanOrEqualTo(340));
    expect(cardSize.height, lessThan(600));
    final topRight = tester.getTopRight(card);
    expect(topRight.dx, greaterThan(1280 * 0.7));
    expect(topRight.dy, lessThan(80));
    expect(find.text('解锁'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('错误 PIN 保留浮动面板并提示，正确 PIN 关闭面板并返回 true', (tester) async {
    _useDesktopViewport(tester);
    final results = <Future<bool?>>[];
    await tester.pumpWidget(_buildHost(_FakeAuthProvider(), results));
    await _openPanel(tester);

    await _enterPin(tester, '111111');
    expect(find.text('PIN 码错误'), findsOneWidget);
    expect(find.byType(UnlockPage), findsOneWidget);
    // 重新输入（清空）时错误提示自动消失
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pump();
    expect(find.text('PIN 码错误'), findsNothing);

    await _enterPin(tester, _correctPin);
    expect(find.byType(UnlockPage), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(await results.single, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点卡片右上角关闭按钮退出浮动面板并返回 false', (tester) async {
    _useDesktopViewport(tester);
    final results = <Future<bool?>>[];
    await tester.pumpWidget(_buildHost(_FakeAuthProvider(), results));
    await _openPanel(tester);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(find.byType(UnlockPage), findsNothing);
    expect(await results.single, isFalse);
    expect(tester.takeException(), isNull);
  });
}
