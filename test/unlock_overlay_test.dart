import 'package:class_score/pages/core/status_bar_layout.dart';
import 'package:class_score/pages/core/unlock_page.dart';
import 'package:class_score/providers/auth_provider.dart';
import 'package:class_score/providers/personalization_provider.dart';
import 'package:class_score/widgets/glass_buttons.dart';
import 'package:class_score/widgets/pin_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' show LiquidOval;
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
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<PersonalizationProvider>(
        create: (_) => PersonalizationProvider(),
      ),
    ],
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
    await tester.tap(find.widgetWithText(GlassActionButton, digit));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 读取模糊层暗化色的不透明度：它随进场进度渐入，用来验证暗化不是硬切。
double _dimAlpha(WidgetTester tester, Finder blurClip) => tester
    .widget<ColoredBox>(
      find.descendant(of: blurClip, matching: find.byType(ColoredBox)),
    )
    .color
    .a;

void main() {
  testWidgets('解锁面板停在状态栏右下方，模糊层整窗渐变并挖空状态栏区域', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHost(_FakeAuthProvider(), []));
    await _openPanel(tester);

    // 模糊层：铺满整窗（状态栏胶囊所在区域由裁剪挖空，见下）
    final blur = find.byType(BackdropFilter);
    expect(blur, findsOneWidget);
    expect(tester.getTopLeft(blur), Offset.zero);
    expect(tester.getSize(blur), const Size(1280, 800));

    // BackdropFilter 的模糊区域由最近的祖先裁剪决定（无 clip 时作用于整屏，
    // 会连状态栏一起糊掉）。这里用 ClipPath 从整窗中挖掉胶囊轮廓，清晰区
    // 边界因此顺着胶囊的圆角走，而不是在状态栏底边横向直切、切断胶囊底部。
    final blurClip = find.byKey(const ValueKey<String>('unlock-blur-clip'));
    expect(blurClip, findsOneWidget);
    expect(find.descendant(of: blurClip, matching: blur), findsOneWidget);
    expect(tester.getSize(blurClip), const Size(1280, 800));

    final clip = tester
        .widget<ClipPath>(blurClip)
        .clipper!
        .getClip(const Size(1280, 800));
    const pillCenterY = StatusBarMetrics.inset + StatusBarMetrics.height / 2;
    // 胶囊自身（状态栏）保持清晰：不落在模糊区域内
    expect(clip.contains(const Offset(640, pillCenterY)), isFalse);
    expect(clip.contains(const Offset(60, pillCenterY)), isFalse);
    // 胶囊上方的留白与下方的内容区都属于模糊区域
    expect(
      clip.contains(const Offset(640, StatusBarMetrics.inset / 2)),
      isTrue,
    );
    expect(clip.contains(Offset(640, StatusBarMetrics.bottom + 100)), isTrue);

    // 卡片：尺寸紧凑 + 停在状态栏右下方，说明是浮动面板而非整屏路由
    final card = find.byType(UnlockPage);
    expect(card, findsOneWidget);
    expect(find.byType(PinPad), findsOneWidget);
    final cardSize = tester.getSize(card);
    expect(cardSize.width, lessThanOrEqualTo(UnlockPage.maxWidth));
    expect(cardSize.height, lessThan(600));
    final topRight = tester.getTopRight(card);
    // 右缘与状态栏胶囊右缘对齐
    expect(topRight.dx, 1280 - StatusBarMetrics.inset);
    // 顶边紧贴状态栏下方
    expect(topRight.dy, StatusBarMetrics.bottom + unlockCardGap);
    expect(find.text('解锁'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('面板从窗口右缘外水平滑入，退场时滑回右侧', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHost(_FakeAuthProvider(), []));

    await tester.tap(find.widgetWithText(ElevatedButton, '打开解锁面板'));
    // 推进到进场动画中段，捕捉卡片尚未就位时的位置
    await tester.pump(const Duration(milliseconds: 60));
    final midRight = tester.getTopRight(find.byType(UnlockPage)).dx;

    await tester.pumpAndSettle();
    final finalRight = tester.getTopRight(find.byType(UnlockPage)).dx;

    // 进场过程中卡片位于最终位置的右侧 → 确实是从右边进入
    expect(midRight, greaterThan(finalRight));
    expect(finalRight, 1280 - StatusBarMetrics.inset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('背景在原地渐变模糊：不跟着卡片平移，暗化程度随进度增长', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHost(_FakeAuthProvider(), []));

    await tester.tap(find.widgetWithText(ElevatedButton, '打开解锁面板'));
    // 第一帧只用于启动路由动画的 ticker，之后再推进到进场动画中段
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final blurClip = find.byKey(const ValueKey<String>('unlock-blur-clip'));
    final midRect = tester.getRect(blurClip);
    final midAlpha = _dimAlpha(tester, blurClip);
    final midCardRight = tester.getTopRight(find.byType(UnlockPage)).dx;

    await tester.pumpAndSettle();
    final settledAlpha = _dimAlpha(tester, blurClip);

    // 模糊层位置/尺寸全程不变：背景不会跟着卡片从右侧滑进来
    expect(tester.getRect(blurClip), midRect);
    expect(
      find.ancestor(
        of: find.byType(BackdropFilter),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
    // 模糊强度（用同步渐变的暗化程度代表）由浅入深 → 背景是渐变进入的
    expect(midAlpha, greaterThan(0));
    expect(midAlpha, lessThan(settledAlpha));
    expect(settledAlpha, closeTo(unlockDimOpacity, 0.001));
    // 同一时刻卡片仍在右侧（进场的位移只作用于卡片）
    expect(midCardRight, greaterThan(1280 - StatusBarMetrics.inset));
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片之上不套透明度层：否则玻璃取不到背景，滑入期间就不糊了', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHost(_FakeAuthProvider(), []));

    await tester.tap(find.widgetWithText(ElevatedButton, '打开解锁面板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // 卡片仍在向最终位置滑入的途中
    final midCardRight = tester.getTopRight(find.byType(UnlockPage)).dx;
    expect(midCardRight, greaterThan(1280 - StatusBarMetrics.inset));

    // 卡片是玻璃容器，它的 BackdropFilter 取的是「已经画在下面的内容」。
    // 祖先一旦有透明度层（Opacity/FadeTransition 会 push 一层临时缓冲），
    // 玻璃取到的 backdrop 就只剩这层空缓冲：卡片滑入期间背景是清晰的，
    // 等淡入结束、透明度层消失才突然变糊。
    for (final type in <Type>[FadeTransition, Opacity, AnimatedOpacity]) {
      expect(
        find.ancestor(of: find.byType(UnlockPage), matching: find.byType(type)),
        findsNothing,
        reason: '卡片上方不应出现 $type',
      );
    }
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
    await tester.tap(find.widgetWithText(GlassActionButton, '清空'));
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

  testWidgets('点击模糊背景关闭面板并返回 false，卡片与状态栏区域不响应', (tester) async {
    _useDesktopViewport(tester);
    final results = <Future<bool?>>[];
    await tester.pumpWidget(_buildHost(_FakeAuthProvider(), results));
    await _openPanel(tester);

    // 卡片空白处（左侧留白）不会误关面板：卡片自身吸收点击
    final cardTopLeft = tester.getTopLeft(find.byType(UnlockPage));
    await tester.tapAt(cardTopLeft + const Offset(4, 8));
    await tester.pumpAndSettle();
    expect(find.byType(UnlockPage), findsOneWidget);

    // 状态栏胶囊所在区域被模糊层挖空：点它不关闭面板
    const pillCenterY = StatusBarMetrics.inset + StatusBarMetrics.height / 2;
    await tester.tapAt(const Offset(640, pillCenterY));
    await tester.pumpAndSettle();
    expect(find.byType(UnlockPage), findsOneWidget);

    // 模糊背景：点一下就关闭，并按「主动关闭」返回 false
    await tester.tapAt(const Offset(640, 400));
    await tester.pumpAndSettle();
    expect(find.byType(UnlockPage), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(await results.single, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片内文字不继承 MaterialApp 的兜底样式（双层黄色下划线）', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHost(_FakeAuthProvider(), []));
    await _openPanel(tester);

    // GlassContainer 不是 Material：若不显式提供 DefaultTextStyle，卡片里的
    // Text 会继承 _errorTextStyle（红色 monospace + 双层黄色下划线）。
    for (final label in ['解锁', '输入 6 位 PIN 码']) {
      final richText = tester.widget<RichText>(
        find.descendant(of: find.text(label), matching: find.byType(RichText)),
      );
      expect(
        (richText.text as TextSpan).style?.decoration ?? TextDecoration.none,
        TextDecoration.none,
        reason: '「$label」不应带下划线',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('数字键盘按键为圆形：宽高相等且形状为液态玻璃圆', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHost(_FakeAuthProvider(), []));
    await _openPanel(tester);

    final key = find.widgetWithText(GlassActionButton, '5');
    expect(key, findsOneWidget);

    final size = tester.getSize(key);
    expect(size.width, size.height);

    final shape = tester.widget<GlassActionButton>(key).shape;
    expect(shape, isA<LiquidOval>());
    expect(tester.takeException(), isNull);
  });
}
