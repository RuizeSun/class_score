import 'dart:typed_data';

import 'package:class_score/models/student.dart';
import 'package:class_score/pages/score/ai_roster/ai_roster_process_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 生成一张 8x8 纯色 PNG，供页面渲染使用。
Uint8List _tinyPng() {
  final image = img.Image(width: 8, height: 8);
  img.fill(image, color: img.ColorRgb8(200, 200, 200));
  return Uint8List.fromList(img.encodePng(image));
}

List<Student> _students() => [
  Student(id: 1, name: '张三', studentNumber: '1401'),
  Student(id: 2, name: '李四', studentNumber: '1402'),
  Student(id: 3, name: '王五', studentNumber: '1403'),
];

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('处理页：左图右规则，默认勾选打勾', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AiRosterProcessPage(imageBytes: _tinyPng(), candidates: _students()),
      ),
    );
    await tester.pumpAndSettle();

    // 设置区标题与规则项都在
    expect(find.text('选择学生的条件'), findsOneWidget);
    expect(find.text('打勾 ✓'), findsOneWidget);
    expect(find.text('打叉 ×'), findsOneWidget);
    expect(find.text('三角形 △'), findsOneWidget);
    expect(find.text('有手写内容'), findsOneWidget);
    expect(find.text('空白（无标记）'), findsOneWidget);
    expect(find.text('开始识别'), findsOneWidget);
    // 识别范围提示
    expect(find.textContaining('3 名学生'), findsOneWidget);

    final checkChip = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, '打勾 ✓'),
    );
    expect(checkChip.selected, isTrue);
  });

  testWidgets('处理页：勾选「空白」会自动取消「有手写内容」', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AiRosterProcessPage(imageBytes: _tinyPng(), candidates: _students()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilterChip, '有手写内容'));
    await tester.pumpAndSettle();
    FilterChip chip(String label) =>
        tester.widget<FilterChip>(find.widgetWithText(FilterChip, label));
    expect(chip('有手写内容').selected, isTrue);

    await tester.tap(find.widgetWithText(FilterChip, '空白（无标记）'));
    await tester.pumpAndSettle();
    expect(chip('空白（无标记）').selected, isTrue);
    expect(chip('有手写内容').selected, isFalse);
  });

  testWidgets('处理页：一条规则都不选时拒绝开始识别', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AiRosterProcessPage(imageBytes: _tinyPng(), candidates: _students()),
      ),
    );
    await tester.pumpAndSettle();

    // 取消默认的打勾
    await tester.tap(find.widgetWithText(FilterChip, '打勾 ✓'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始识别'));
    await tester.pump();

    expect(find.text('请至少选择一种选中条件'), findsOneWidget);
  });

  testWidgets('处理页：没有学生时提示先添加学生', (tester) async {
    await tester.pumpWidget(
      _wrap(AiRosterProcessPage(imageBytes: _tinyPng(), candidates: const [])),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始识别'));
    await tester.pump();

    expect(find.text('当前没有学生，请先添加学生'), findsOneWidget);
  });
}
