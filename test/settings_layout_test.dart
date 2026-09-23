import 'package:class_score/models/group.dart';
import 'package:class_score/models/score_item.dart';
import 'package:class_score/pages/settings/settings_common.dart';
import 'package:class_score/pages/settings/settings_hub_page.dart';
import 'package:class_score/providers/auth_provider.dart';
import 'package:class_score/providers/desktop_schedule_provider.dart';
import 'package:class_score/providers/group_provider.dart';
import 'package:class_score/providers/personalization_provider.dart';
import 'package:class_score/providers/score_item_provider.dart';
import 'package:class_score/providers/score_provider.dart';
import 'package:class_score/providers/student_provider.dart';
import 'package:class_score/widgets/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 仅提供内存数据的 Provider 集合，避免测试中访问数据库。

class _FakeGroupProvider extends GroupProvider {
  _FakeGroupProvider(this._data);

  final List<Group> _data;

  @override
  List<Group> get groups => _data;

  @override
  Future<void> loadGroups() async {}
}

class _FakeStudentProvider extends StudentProvider {
  _FakeStudentProvider(this._data);

  final List<Map<String, dynamic>> _data;

  @override
  List<Map<String, dynamic>> get studentsWithGroup => _data;

  @override
  Future<void> loadStudents({int? groupId}) async {}
}

class _FakeScoreItemProvider extends ScoreItemProvider {
  _FakeScoreItemProvider(this._data);

  final List<ScoreItem> _data;

  @override
  List<ScoreItem> get items => _data;

  @override
  Future<void> loadItems() async {}
}

class _FakeScoreProvider extends ScoreProvider {
  /// 记录被切换的统计显示开关，避免测试中写数据库。
  bool? mergeSameRankSet;
  bool? competitionRankingSet;

  @override
  Future<void> loadScoreConfig() async {}

  @override
  Future<void> setMergeSameRank(bool value) async {
    mergeSameRankSet = value;
  }

  @override
  Future<void> setCompetitionRanking(bool value) async {
    competitionRankingSet = value;
  }
}

class _FakeAuthProvider extends AuthProvider {
  @override
  List<Map<String, dynamic>> get courseSchedules => const [];
}

Widget _buildHub({
  List<Group> groups = const [],
  List<Map<String, dynamic>> students = const [],
  List<ScoreItem> items = const [],
  ScoreProvider? scoreProvider,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PersonalizationProvider>(
        create: (_) => PersonalizationProvider(),
      ),
      ChangeNotifierProvider<AuthProvider>(create: (_) => _FakeAuthProvider()),
      ChangeNotifierProvider<GroupProvider>(
        create: (_) => _FakeGroupProvider(groups),
      ),
      ChangeNotifierProvider<StudentProvider>(
        create: (_) => _FakeStudentProvider(students),
      ),
      ChangeNotifierProvider<ScoreProvider>(
        create: (_) => scoreProvider ?? _FakeScoreProvider(),
      ),
      ChangeNotifierProvider<ScoreItemProvider>(
        create: (_) => _FakeScoreItemProvider(items),
      ),
      // 桌面课表：设置页的「桌面课表」分项会读它（含实时预览）；
      // 这里用真实 Provider，构造函数不访问数据库，读取的也都是内存状态。
      ChangeNotifierProvider<DesktopScheduleProvider>(
        create: (_) => DesktopScheduleProvider(),
      ),
    ],
    child: const MaterialApp(home: SettingsHubPage()),
  );
}

/// 设置 Tab 下的 10 个分项（与侧边栏文案一致）。
const List<String> _sectionTitles = [
  '个性化',
  '分组管理',
  '学生管理',
  '预设评分项',
  '计分规则',
  '课程表管理',
  '桌面课表',
  '评分周期',
  '物理密钥管理',
  '系统设置',
];

Future<void> _openSection(WidgetTester tester, String title) async {
  await tester.tap(find.widgetWithText(ListTile, title));
  await tester.pumpAndSettle();
}

void _useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 取组件最近一层 [FadeTransition] 的不透明度，用于断言过渡进程。
double _fadeOpacity(WidgetTester tester, Finder finder) => tester
    .widget<FadeTransition>(
      find.ancestor(of: finder, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

void main() {
  testWidgets('各分项：统一页头且不再使用卡片（1280x800 无溢出）', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHub());
    await tester.pumpAndSettle();

    for (final title in _sectionTitles) {
      await _openSection(tester, title);

      expect(
        find.byType(SettingsSectionScaffold),
        findsOneWidget,
        reason: '$title 应使用统一骨架',
      );
      // 页头标题唯一：分项内部不再重复渲染标题（侧边栏同名条目不计入）
      expect(
        find.descendant(
          of: find.byType(SettingsSectionScaffold),
          matching: find.text(title),
        ),
        findsOneWidget,
        reason: '$title 页头标题应只出现一次',
      );
      // 设置页不再使用卡片
      expect(find.byType(Card), findsNothing, reason: '$title 不应使用卡片');
      expect(tester.takeException(), isNull, reason: '$title 渲染不应出错');
    }
  });

  testWidgets('列表型分项空状态统一为图标 + 主提示 + 次要提示', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHub());
    await tester.pumpAndSettle();

    const expected = <String, String>{
      '分组管理': '暂无分组',
      '学生管理': '暂无学生',
      '预设评分项': '暂无预设评分项',
      '物理密钥管理': '暂无已注册的 U 盘密钥',
    };

    for (final entry in expected.entries) {
      await _openSection(tester, entry.key);

      final emptyState = find.byType(SettingsEmptyState);
      expect(emptyState, findsOneWidget, reason: '${entry.key} 空状态应使用统一组件');
      expect(
        find.descendant(of: emptyState, matching: find.byType(Icon)),
        findsOneWidget,
        reason: '${entry.key} 空状态应包含图标',
      );
      expect(find.text(entry.value), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('主操作入口统一位于内容区顶部工具栏', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHub(groups: [Group(id: 1, name: '第一组')]));
    await tester.pumpAndSettle();

    const toolbarButtons = <String, String>{
      '分组管理': '添加小组',
      '学生管理': '添加学生',
      '预设评分项': '添加评分项',
      '物理密钥管理': '写入密钥',
    };

    for (final entry in toolbarButtons.entries) {
      await _openSection(tester, entry.key);

      final toolbar = find.byType(SettingsToolbar);
      expect(toolbar, findsOneWidget, reason: '${entry.key} 应有统一工具栏');

      final button = find.widgetWithText(FilledButton, entry.value);
      expect(
        button,
        findsOneWidget,
        reason: '${entry.key} 缺少 ${entry.value} 按钮',
      );
      expect(
        find.descendant(of: toolbar, matching: button),
        findsOneWidget,
        reason: '${entry.key} 的 ${entry.value} 应位于工具栏内',
      );

      // 主操作不再使用悬浮 FAB
      expect(
        find.byType(FloatingActionButton),
        findsNothing,
        reason: '${entry.key} 不应再使用 FAB',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('分项切换：旧分项淡出、新分项淡入，过渡中两层不叠影', (tester) async {
    _useDesktopViewport(tester);
    await tester.pumpWidget(_buildHub(groups: [Group(id: 1, name: '第一组')]));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsSectionScaffold), findsOneWidget);
    expect(find.byType(FadeThroughSwitcher), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, '分组管理'));
    await tester.pump();
    // 过渡前半段：新分项已在树中，但尚未开始淡入
    await tester.pump(const Duration(milliseconds: 90));
    expect(_fadeOpacity(tester, find.text('第一组')), 0);

    // 过渡后半段：新分项开始淡入
    await tester.pump(const Duration(milliseconds: 60));
    expect(_fadeOpacity(tester, find.text('第一组')), greaterThan(0));

    // 过渡结束：只剩目标分项，且不再有残影
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSectionScaffold), findsOneWidget);
    expect(_fadeOpacity(tester, find.text('第一组')), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('计分规则：统计报表的「同名次合并 / 并列名次跳号」可切换，默认都开启', (tester) async {
    _useDesktopViewport(tester);
    final scoreProvider = _FakeScoreProvider();
    await tester.pumpWidget(_buildHub(scoreProvider: scoreProvider));
    await tester.pumpAndSettle();

    await _openSection(tester, '计分规则');

    final mergeTile = find.widgetWithText(SwitchListTile, '同名次合并显示');
    final skipTile = find.widgetWithText(SwitchListTile, '并列名次按实际位置跳号');
    expect(mergeTile, findsOneWidget);
    expect(skipTile, findsOneWidget);
    // 默认两项都开启：并列名次按实际位置跳号（100、99、99、98 → 第1、第2、第2、第4名）
    expect(tester.widget<SwitchListTile>(mergeTile).value, isTrue);
    expect(tester.widget<SwitchListTile>(skipTile).value, isTrue);
    // 两种编号写法都写在说明里，便于按需求切换
    expect(find.textContaining('第1、第2、第2、第4名'), findsOneWidget);
    expect(find.textContaining('第1、第2、第2、第3名'), findsOneWidget);

    // 关闭「并列名次跳号」→ 落库为紧凑名次
    await tester.ensureVisible(skipTile);
    await tester.pumpAndSettle();
    await tester.tap(skipTile);
    await tester.pumpAndSettle();
    expect(scoreProvider.competitionRankingSet, isFalse);

    // 关闭「同名次合并」→ 每行独立成块
    await tester.tap(mergeTile);
    await tester.pumpAndSettle();
    expect(scoreProvider.mergeSameRankSet, isFalse);
    expect(tester.takeException(), isNull);
  });
}
