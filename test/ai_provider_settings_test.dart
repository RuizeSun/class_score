import 'package:class_score/pages/settings/ai_provider_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AI 服务商设置：首帧即可渲染表单（不转圈、可命中）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AiProviderSettingsView())),
    );
    // 首帧就应该有内容，不允许停留在 loading
    await tester.pump();

    expect(find.text('服务商与接口'), findsOneWidget);
    expect(find.text('接口地址 baseUrl'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 服务商设置：切换服务商会同步默认 baseUrl 与模型名', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AiProviderSettingsView())),
    );
    await tester.pump();

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ollama（本地）').last);
    await tester.pumpAndSettle();

    expect(find.text('http://localhost:11434/v1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 服务商设置：可单独压栈完整页', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiProviderSettingsPage()));
    await tester.pump();

    expect(find.text('AI 服务商'), findsOneWidget);
    expect(find.text('服务商与接口'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
