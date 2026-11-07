import 'package:class_score/pages/settings/sync_settings_view.dart';
import 'package:class_score/sync/sync_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「两端都有数据」时，设置页必须把选择权交给老师。
///
/// 这一屏存在的理由：首次配对时如果服务端已经有数据（大屏早就在用、服务端
/// 是新装的镜像，或者反过来），**自动挑一边等于替老师丢掉另一份数据**。
/// 所以这里既不能静默上传，也不能静默覆盖，必须停下来问。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('三选一面板把三个选项都摆出来', (tester) async {
    final chosen = <MergeChoice>[];
    await tester.pumpWidget(
      wrap(
        MergeDecisionPanel(
          preview: const InitialMergePreview(
            localRows: 12,
            remoteRows: 7,
            remoteMaxRev: 33,
          ),
          busy: false,
          onChoose: chosen.add,
        ),
      ),
    );

    expect(find.text('首次同步：两端都有数据'), findsOneWidget);
    // 两边行数要露出来，老师才知道自己在选什么。
    // 文案是拼出来的（'本地 12 行 · 服务端 7 行'），所以要按子串找。
    expect(find.textContaining('本地 12 行'), findsOneWidget);
    expect(find.textContaining('服务端 7 行'), findsOneWidget);

    await tester.tap(find.text('合并（推荐）'));
    await tester.tap(find.text('保留本地'));
    await tester.tap(find.text('保留远端'));
    await tester.pump();

    expect(chosen, [
      MergeChoice.merge,
      MergeChoice.keepLocal,
      MergeChoice.keepRemote,
    ]);
  });

  testWidgets('忙的时候三个按钮都禁用，避免重复提交', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      wrap(
        MergeDecisionPanel(
          preview: const InitialMergePreview(
            localRows: 1,
            remoteRows: 1,
            remoteMaxRev: 1,
          ),
          busy: true,
          onChoose: (_) => taps++,
        ),
      ),
    );

    await tester.tap(find.text('合并（推荐）'));
    await tester.tap(find.text('保留本地'));
    await tester.tap(find.text('保留远端'));
    await tester.pump();
    expect(taps, 0, reason: '上传/拉取期间不该再接受新的选择');
  });

  testWidgets('说明文字必须写清每种选择会丢什么', (tester) async {
    await tester.pumpWidget(
      wrap(
        MergeDecisionPanel(
          preview: const InitialMergePreview(
            localRows: 1,
            remoteRows: 1,
            remoteMaxRev: 1,
          ),
          busy: false,
          onChoose: (_) {},
        ),
      ),
    );

    // 这三条是用户做决定唯一依据，少一条都会让人不敢点
    expect(find.textContaining('两边都不丢'), findsOneWidget);
    expect(find.textContaining('覆盖'), findsWidgets);
    expect(find.textContaining('消失'), findsWidgets);
    expect(find.textContaining('回收站'), findsOneWidget);
  });
}
