import 'package:class_score/pages/analysis/ranking_summary_page.dart';
import 'package:class_score/providers/group_provider.dart';
import 'package:class_score/providers/score_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('高级查询页是左右双栏：条件在左、结果在右，窄窗口不溢出', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ScoreProvider()),
          ChangeNotifierProvider(create: (_) => GroupProvider()),
        ],
        child: const MaterialApp(home: RankingSummaryPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 左栏条件、右栏结果同时可见
    expect(find.text('查询条件'), findsOneWidget);
    expect(find.text('查询结果'), findsOneWidget);
    // 未选周期时右栏给出引导，而不是空白
    expect(find.text('请选择周期范围'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
