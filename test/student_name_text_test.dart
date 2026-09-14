import 'package:class_score/widgets/student_name_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「姓名#学号（学号灰色）」显示规范的回归用例。
void main() {
  /// 收集 [InlineSpan] 中所有带文本的片段。
  ///
  /// `Text.rich` 会在最外层再包一层样式 `TextSpan`，因此不能直接取第一层 children。
  List<TextSpan> collectTextSpans(InlineSpan span) {
    final result = <TextSpan>[];
    void visit(InlineSpan node) {
      if (node is! TextSpan) return;
      if (node.text != null) result.add(node);
      for (final child in node.children ?? const <InlineSpan>[]) {
        visit(child);
      }
    }

    visit(span);
    return result;
  }

  group('StudentDisplay.plainText', () {
    test('使用「姓名#学号」格式', () {
      expect(StudentDisplay.plainText('张三', '001'), '张三#001');
    });

    test('学号为空时只显示姓名，不出现分隔符', () {
      expect(StudentDisplay.plainText('张三', ''), '张三');
    });
  });

  group('StudentDisplay.numberColorFor', () {
    test('姓名无色时为默认灰色', () {
      expect(StudentDisplay.numberColorFor(null), StudentDisplay.numberColor);
    });

    test('姓名为中性色（黑/白）时仍为灰色', () {
      expect(
        StudentDisplay.numberColorFor(Colors.black87),
        StudentDisplay.numberColor,
      );
      expect(
        StudentDisplay.numberColorFor(Colors.white),
        StudentDisplay.numberColor,
      );
    });

    test('姓名带色时跟随同色并降低不透明度', () {
      final green = Colors.green.shade700;
      expect(
        StudentDisplay.numberColorFor(green),
        green.withValues(alpha: StudentDisplay.numberAlpha),
      );
    });
  });

  group('StudentDisplay.span', () {
    test('拆分为「姓名」+「#学号」两段，学号段为灰色', () {
      final span =
          StudentDisplay.span(name: '张三', studentNumber: '001') as TextSpan;
      final children = span.children!.cast<TextSpan>();

      expect(children, hasLength(2));
      expect(children[0].text, '张三');
      expect(children[1].text, '#001');
      expect(children[1].style!.color, StudentDisplay.numberColor);
    });

    test('学号为空时只有一段，且不带样式覆盖', () {
      final span = StudentDisplay.span(name: '张三', studentNumber: '');
      expect(span.toPlainText(), '张三');
      expect((span as TextSpan).children, isNull);
    });

    test('姓名样式为彩色时，学号段继承同色降不透明度', () {
      final style = TextStyle(fontSize: 12, color: Colors.green.shade700);
      final span =
          StudentDisplay.span(
                name: '张三',
                studentNumber: '001',
                nameStyle: style,
              )
              as TextSpan;
      final numberSpan = (span.children!.last as TextSpan);

      expect(numberSpan.style!.fontSize, 12);
      expect(
        numberSpan.style!.color,
        Colors.green.shade700.withValues(alpha: StudentDisplay.numberAlpha),
      );
    });
  });

  testWidgets('StudentNameText 渲染为「姓名#学号」，学号为灰色', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StudentNameText(name: '张三', studentNumber: '001'),
        ),
      ),
    );

    expect(find.text('张三#001', findRichText: true), findsOneWidget);

    final richText = tester.widget<RichText>(find.byType(RichText));
    final spans = collectTextSpans(richText.text);

    expect(spans.map((s) => s.text), ['张三', '#001']);
    expect(spans.last.style!.color, StudentDisplay.numberColor);
  });

  testWidgets('StudentNameText 学号为空时只渲染姓名', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StudentNameText(name: '张三', studentNumber: ''),
        ),
      ),
    );

    expect(find.text('张三', findRichText: true), findsOneWidget);
    expect(find.textContaining('#', findRichText: true), findsNothing);
  });
}
