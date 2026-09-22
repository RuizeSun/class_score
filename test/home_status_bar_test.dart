import 'package:class_score/pages/core/home_status_bar.dart';
import 'package:class_score/pages/core/status_bar_layout.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    MaterialApp(
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
  );
}

/// 找到承载胶囊圆角裁剪的 [ClipPath]（按钮的祖先）。
Finder _capsuleClip(Finder button) =>
    find.ancestor(of: button, matching: find.byType(ClipPath));

/// 取出按钮悬停（hover）时生效的形状：叠层高亮 / 水波纹就按这个形状绘制。
ShapeBorder _hoverShape(WidgetTester tester, Finder button) => tester
    .widget<TextButton>(button)
    .style!
    .shape!
    .resolve(const <WidgetState>{WidgetState.hovered})!;

/// 断言按钮的悬停叠层是「胶囊（跑道）形」。
///
/// [atCapsuleEnd] 为真时（最右侧按钮）进一步断言叠层的右端半圆与状态栏
/// 胶囊的右端半圆重合：悬停时看起来就是胶囊右端被点亮。
void _expectCapsuleOverlay(
  WidgetTester tester, {
  required Finder button,
  required Rect capsuleRect,
  bool atCapsuleEnd = false,
}) {
  final buttonRect = tester.getRect(button);
  // 按钮被 Row 拉伸到与胶囊等高
  expect(buttonRect.height, StatusBarMetrics.height);
  expect(buttonRect.top, capsuleRect.top);
  expect(buttonRect.bottom, capsuleRect.bottom);

  final shape = _hoverShape(tester, button);
  expect(shape, isA<StadiumBorder>(), reason: '叠层形状应为胶囊（跑道）形');

  // 跑道形：矩形四角落在形状之外、中线仍在形状内（半径 = 高度 / 2）
  final path = shape.getOuterPath(Offset.zero & buttonRect.size);
  expect(path.contains(const Offset(0.5, 0.5)), isFalse);
  expect(path.contains(Offset(buttonRect.width - 0.5, 0.5)), isFalse);
  expect(
    path.contains(Offset(buttonRect.width / 2, buttonRect.height / 2)),
    isTrue,
  );

  // 叠层半径 = 按钮高度 / 2 = 胶囊半径：叠层与状态栏是同一种「胶囊」
  final radius = buttonRect.height / 2;
  expect(radius, StatusBarMetrics.radius);

  if (!atCapsuleEnd) return;

  // 最右侧按钮的右缘与胶囊右缘对齐，于是叠层右端半圆的圆心与胶囊右端
  // 半圆的圆心重合 —— 悬停时就是胶囊右端被点亮，而不是方角阴影贴上去。
  expect(buttonRect.right, capsuleRect.right);
  expect(
    buttonRect.right - radius - capsuleRect.left,
    capsuleRect.width - StatusBarMetrics.radius,
  );
  expect(buttonRect.center.dy - capsuleRect.top, StatusBarMetrics.height / 2);
}

void main() {
  testWidgets('解锁按钮的悬停叠层为胶囊形，且被胶囊兜底裁剪', (tester) async {
    await _pumpStatusBar(tester, isUnlocked: false);

    final unlockButton = find.widgetWithText(TextButton, '解锁');
    expect(unlockButton, findsOneWidget);

    // 胶囊仍保留一层裁剪（布局变化时的兜底）：按钮的悬停高亮 / 水波纹虽然
    // 已经改成胶囊形，但它是由按钮自身的 Material 绘制的一层叠层，不受
    // 祖先装饰约束，因此这里把子组件整体裁进胶囊轮廓。
    final clipPath = _capsuleClip(unlockButton);
    expect(clipPath, findsOneWidget);
    expect(
      find.descendant(of: clipPath, matching: find.byType(Material)),
      findsWidgets,
      reason: '按钮（连同它自己绘制高亮的 Material）应位于裁剪之内',
    );

    final size = tester.getSize(clipPath);
    final clip = tester.widget<ClipPath>(clipPath).clipper!.getClip(size);

    // 裁剪形状 = 胶囊自身：正中在裁剪内，四个圆角在裁剪外
    expect(clip.contains(Offset(size.width / 2, size.height / 2)), isTrue);
    expect(clip.contains(const Offset(1, 1)), isFalse);
    expect(clip.contains(Offset(size.width - 1, size.height - 1)), isFalse);

    _expectCapsuleOverlay(
      tester,
      button: unlockButton,
      capsuleRect: tester.getRect(clipPath),
      atCapsuleEnd: true,
    );

    // 裁剪切确实覆盖了按钮中心：兜底裁剪不会把按钮整个吃掉
    final buttonRect = tester.getRect(unlockButton);
    final capsuleRect = tester.getRect(clipPath);
    expect(
      clip.contains(
        Offset(
          buttonRect.center.dx - capsuleRect.left,
          buttonRect.center.dy - capsuleRect.top,
        ),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('已解锁时右侧「密钥」「上锁」按钮的悬停叠层同样是胶囊形', (tester) async {
    await _pumpStatusBar(tester, isUnlocked: true);

    expect(find.widgetWithText(TextButton, '密钥'), findsOneWidget);
    final lockButton = find.widgetWithText(TextButton, '上锁');
    expect(lockButton, findsOneWidget);
    // 未解锁时显示的「解锁」按钮此时不再出现
    expect(find.widgetWithText(TextButton, '解锁'), findsNothing);

    final clipPath = _capsuleClip(lockButton);
    expect(clipPath, findsOneWidget);
    final size = tester.getSize(clipPath);
    final capsuleRect = tester.getRect(clipPath);

    _expectCapsuleOverlay(
      tester,
      button: lockButton,
      capsuleRect: capsuleRect,
      atCapsuleEnd: true,
    );
    _expectCapsuleOverlay(
      tester,
      button: find.widgetWithText(TextButton, '密钥'),
      capsuleRect: capsuleRect,
    );

    // 悬浮到最右侧按钮上：叠层按胶囊形绘制，不撑大胶囊、不抛异常
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(lockButton));
    await tester.pumpAndSettle();

    expect(tester.getSize(clipPath), size);
    expect(tester.takeException(), isNull);
  });
}
