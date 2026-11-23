import 'package:class_score/pages/core/home_status_bar.dart';
import 'package:class_score/pages/core/status_bar_layout.dart';
import 'package:class_score/providers/personalization_provider.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 以桌面尺寸渲染状态栏（宽胶囊 + 右侧按钮），并关掉窗口相关的初始化。
Future<void> _pumpStatusBar(
  WidgetTester tester, {
  required bool isUnlocked,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ChangeNotifierProvider<PersonalizationProvider>(
      create: (_) => PersonalizationProvider(),
      child: MaterialApp(
        home: Scaffold(
          body: HomeStatusBar(
            isUnlocked: isUnlocked,
            currentCourseName: '语文',
            onUnlock: () {},
            onShowUsbKey: () {},
            onLock: () {},
          ),
        ),
      ),
    ),
  );
}

/// 状态栏胶囊的兜底裁剪（[StadiumBorder]，与胶囊自身轮廓一致）。
Finder _capsuleClip() => find.byWidgetPredicate(
  (widget) =>
      widget is ClipPath &&
      widget.clipper is ShapeBorderClipper &&
      (widget.clipper! as ShapeBorderClipper).shape is StadiumBorder,
);

/// 按钮悬停时叠层使用的形状。
ShapeBorder _hoverShape(WidgetTester tester, Finder button) => tester
    .widget<TextButton>(button)
    .style!
    .shape!
    .resolve(const <WidgetState>{WidgetState.hovered})!;

void main() {
  testWidgets('解锁按钮不使用液态玻璃背景，悬停叠层为胶囊形', (tester) async {
    await _pumpStatusBar(tester, isUnlocked: false);

    final unlockButton = find.widgetWithText(TextButton, '解锁');
    expect(unlockButton, findsOneWidget);

    final clipPath = _capsuleClip();
    expect(clipPath, findsOneWidget);
    expect(
      find.descendant(of: clipPath, matching: unlockButton),
      findsOneWidget,
      reason: '按钮应位于胶囊兜底裁剪之内',
    );

    final size = tester.getSize(clipPath);
    final clip = tester.widget<ClipPath>(clipPath).clipper!.getClip(size);

    // 裁剪形状 = 胶囊自身：正中在裁剪内，四个圆角在裁剪外
    expect(clip.contains(Offset(size.width / 2, size.height / 2)), isTrue);
    expect(clip.contains(const Offset(1, 1)), isFalse);
    expect(clip.contains(Offset(size.width - 1, size.height - 1)), isFalse);

    // 状态栏本身是玻璃胶囊，右侧按钮保持普通图标 + 文字
    expect(_hoverShape(tester, unlockButton), isA<StadiumBorder>());

    // 按钮被 Row 拉伸到与胶囊等高，最右侧按钮的右缘与胶囊右缘对齐
    final buttonRect = tester.getRect(unlockButton);
    final capsuleRect = tester.getRect(clipPath);
    expect(buttonRect.height, StatusBarMetrics.height);
    expect(buttonRect.top, capsuleRect.top);
    expect(buttonRect.bottom, capsuleRect.bottom);
    expect(buttonRect.right, capsuleRect.right);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已解锁时「密钥」「上锁」同样是普通按钮', (tester) async {
    await _pumpStatusBar(tester, isUnlocked: true);

    expect(find.widgetWithText(TextButton, '密钥'), findsOneWidget);
    final lockButton = find.widgetWithText(TextButton, '上锁');
    expect(lockButton, findsOneWidget);
    // 未解锁时显示的「解锁」按钮此时不再出现
    expect(find.widgetWithText(TextButton, '解锁'), findsNothing);

    expect(_hoverShape(tester, lockButton), isA<StadiumBorder>());
    expect(
      _hoverShape(tester, find.widgetWithText(TextButton, '密钥')),
      isA<StadiumBorder>(),
    );

    final clipPath = _capsuleClip();
    expect(clipPath, findsOneWidget);
    final capsuleRect = tester.getRect(clipPath);
    final lockRect = tester.getRect(lockButton);
    final keyRect = tester.getRect(find.widgetWithText(TextButton, '密钥'));

    expect(lockRect.height, StatusBarMetrics.height);
    expect(keyRect.height, StatusBarMetrics.height);
    expect(lockRect.right, capsuleRect.right);
    expect(keyRect.left, greaterThanOrEqualTo(capsuleRect.left));

    // 悬浮到最右侧按钮上：不撑大胶囊、不抛异常
    final size = tester.getSize(clipPath);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(lockButton));
    await tester.pumpAndSettle();

    expect(tester.getSize(clipPath), size);
    expect(tester.takeException(), isNull);
  });
}
