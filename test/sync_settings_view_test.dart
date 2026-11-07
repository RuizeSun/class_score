import 'package:class_score/models/group.dart';
import 'package:class_score/models/score_item.dart';
import 'package:class_score/pages/settings/settings_hub_page.dart';
import 'package:class_score/providers/auth_provider.dart';
import 'package:class_score/providers/desktop_schedule_provider.dart';
import 'package:class_score/providers/group_provider.dart';
import 'package:class_score/providers/personalization_provider.dart';
import 'package:class_score/providers/score_item_provider.dart';
import 'package:class_score/providers/score_provider.dart';
import 'package:class_score/providers/student_provider.dart';
import 'package:class_score/pages/settings/settings_common.dart';
import 'package:class_score/providers/sync_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeGroupProvider extends GroupProvider {
  @override
  List<Group> get groups => const [];
  @override
  Future<void> loadGroups() async {}
}

class _FakeStudentProvider extends StudentProvider {
  @override
  List<Map<String, dynamic>> get studentsWithGroup => const [];
  @override
  Future<void> loadStudents({int? groupId}) async {}
}

class _FakeScoreItemProvider extends ScoreItemProvider {
  @override
  List<ScoreItem> get items => const [];
  @override
  Future<void> loadItems() async {}
}

class _FakeScoreProvider extends ScoreProvider {
  @override
  Future<void> loadScoreConfig() async {}
}

class _FakeAuthProvider extends AuthProvider {
  @override
  List<Map<String, dynamic>> get courseSchedules => const [];
}

void main() {
  testWidgets('同步服务：渲染无异常、复用统一骨架、不使用卡片', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PersonalizationProvider>(
            create: (_) => PersonalizationProvider(),
          ),
          ChangeNotifierProvider<AuthProvider>(create: (_) => _FakeAuthProvider()),
          ChangeNotifierProvider<GroupProvider>(
            create: (_) => _FakeGroupProvider(),
          ),
          ChangeNotifierProvider<StudentProvider>(
            create: (_) => _FakeStudentProvider(),
          ),
          ChangeNotifierProvider<ScoreProvider>(
            create: (_) => _FakeScoreProvider(),
          ),
          ChangeNotifierProvider<ScoreItemProvider>(
            create: (_) => _FakeScoreItemProvider(),
          ),
          ChangeNotifierProvider<DesktopScheduleProvider>(
            create: (_) => DesktopScheduleProvider(),
          ),
          ChangeNotifierProvider<SyncProvider>(create: (_) => SyncProvider()),
        ],
        child: const MaterialApp(home: SettingsHubPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, '同步服务'));
    await tester.pumpAndSettle();

    // 1) 不抛异常（曾经嵌套两层 SettingsSectionScaffold，导致无界高度断言）
    expect(tester.takeException(), isNull);
    // 2) 骨架由 SettingsHubPage 提供，且只有一个（页头标题只出现一次）
    expect(find.byType(SettingsSectionScaffold), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SettingsSectionScaffold),
        matching: find.text('同步服务'),
      ),
      findsOneWidget,
    );
    // 3) 设置页统一约定：不使用卡片
    expect(find.byType(Card), findsNothing);
    // 4) 配对入口可用
    expect(find.widgetWithText(FilledButton, '配对'), findsOneWidget);
    // 5) 未配对时三个"已连接"操作都不可点（避免点了没反应）
    expect(find.widgetWithText(OutlinedButton, '解除绑定'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '立即同步'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '全量对齐'), findsOneWidget);
    for (final label in ['解除绑定', '立即同步', '全量对齐']) {
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, label),
      );
      expect(button.onPressed, isNull, reason: '未配对时「$label」应当禁用');
    }
  });
}
