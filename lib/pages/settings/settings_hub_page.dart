import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/group_provider.dart';
import '../../providers/student_provider.dart';
import '../../providers/score_item_provider.dart';
import 'pin_dialogs.dart';
import 'group_management.dart';
import 'student_management.dart';
import 'score_items_management.dart';
import 'course_schedule_management.dart';
import 'usb_key_management.dart';
import 'system_settings.dart';
import 'period_management.dart';
import 'personalization_view.dart';
import 'scoring_rules_view.dart';
import 'settings_common.dart';
import '../../widgets/motion.dart';
import '../../models/group.dart';
import '../../models/student.dart';
import '../../models/score_item.dart';

class SettingsHubPage extends StatefulWidget {
  const SettingsHubPage({super.key});

  @override
  State<SettingsHubPage> createState() => _SettingsHubPageState();
}

enum SettingsSection {
  personalization,
  group,
  student,
  scoreItems,
  scoringRules,
  courseSchedule,
  period,
  usbKey,
  system,
}

class _SettingsHubPageState extends State<SettingsHubPage> {
  static const double _breakpoint = 800;
  static const double _sidebarWidth = 260;

  SettingsSection _current = SettingsSection.personalization;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GroupProvider>().loadGroups();
      context.read<StudentProvider>().loadStudents();
      context.read<ScoreItemProvider>().loadItems();
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _breakpoint;
        final sidebar = _buildSidebar(isWide);

        return Scaffold(
          appBar: AppBar(
            title: Text(_titleOf(_current)),
            leading: isWide
                ? null
                : Builder(
                    builder: (ctx) => IconButton(
                      icon: const Icon(Icons.menu),
                      onPressed: () => Scaffold.of(ctx).openDrawer(),
                    ),
                  ),
          ),
          drawer: isWide ? null : Drawer(child: sidebar),
          body: isWide
              ? Row(
                  children: [
                    sidebar,
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildContent(context)),
                  ],
                )
              : _buildContent(context),
        );
      },
    );
  }

  Widget _buildSidebar(bool isWide) {
    Widget item(IconData icon, String text, SettingsSection section) {
      return ListTile(
        leading: Icon(icon),
        title: Text(text),
        selected: _current == section,
        onTap: () {
          setState(() => _current = section);
          if (!isWide && mounted) Navigator.of(context).pop();
        },
      );
    }

    return SizedBox(
      width: _sidebarWidth,
      child: ListView(
        children: [
          item(Icons.palette, '个性化', SettingsSection.personalization),
          const Divider(),
          item(Icons.group, '分组管理', SettingsSection.group),
          item(Icons.person, '学生管理', SettingsSection.student),
          item(Icons.list_alt, '预设评分项', SettingsSection.scoreItems),
          item(Icons.rule, '计分规则', SettingsSection.scoringRules),
          item(Icons.calendar_month, '课程表管理', SettingsSection.courseSchedule),
          item(Icons.calendar_today, '评分周期', SettingsSection.period),
          item(Icons.usb, '物理密钥管理', SettingsSection.usbKey),
          const Divider(),
          item(Icons.settings, '系统设置', SettingsSection.system),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final section = _current;
    // 分项切换（页头 + 内容）整体淡入上移：过去是硬切，且各分项高度不同，
    // 切换时会突兀地跳一下
    return FadeThroughSwitcher(
      switchKey: section,
      expand: true,
      child: SettingsSectionScaffold(
        title: _titleOf(section),
        subtitle: _subtitleOf(section),
        scrollable: _isScrollable(section),
        child: _buildSectionActions(context),
      ),
    );
  }

  /// 表单型分项由骨架提供滚动；列表型分项由自身 ListView 滚动。
  bool _isScrollable(SettingsSection section) {
    switch (section) {
      case SettingsSection.personalization:
      case SettingsSection.scoringRules:
      case SettingsSection.period:
      case SettingsSection.system:
        return true;
      case SettingsSection.group:
      case SettingsSection.student:
      case SettingsSection.scoreItems:
      case SettingsSection.courseSchedule:
      case SettingsSection.usbKey:
        return false;
    }
  }

  /// 各分项统一页头说明。
  String _subtitleOf(SettingsSection section) {
    switch (section) {
      case SettingsSection.personalization:
        return '选择主题色，并控制锁定状态下的窗口行为。';
      case SettingsSection.group:
        return '维护小组，支持查看成员与批量调整分组。';
      case SettingsSection.student:
        return '维护学生信息与所属小组，支持从 CSV / Excel 批量导入。';
      case SettingsSection.scoreItems:
        return '维护评分页可快速使用的预设评分项。';
      case SettingsSection.scoringRules:
        return '统一设置初始分、小组总分计算方式与允许分值范围。';
      case SettingsSection.courseSchedule:
        return '维护课程表，支持网格 / 表格编辑与批量导入。';
      case SettingsSection.period:
        return '查看当前评分周期，并可切换到上一 / 下一周期。';
      case SettingsSection.usbKey:
        return '管理用于解锁应用的 U 盘物理密钥。';
      case SettingsSection.system:
        return '密码解锁、数据备份导出与重置操作。';
    }
  }

  Widget _buildSectionActions(BuildContext context) {
    switch (_current) {
      case SettingsSection.group:
        return GroupManagementView(
          onShowGroupDialog: ({Group? group}) =>
              showGroupDialog(context, group: group),
          onShowGroupMembers: (Group group) => showGroupMembers(context, group),
        );
      case SettingsSection.student:
        return StudentManagementView(
          onShowStudentDialog: ({Student? student}) =>
              showStudentDialog(context, student: student),
        );
      case SettingsSection.scoreItems:
        return ScoreItemsManagementView(
          onShowItemDialog: ({ScoreItem? item}) =>
              showScoreItemDialog(context, item: item),
        );
      case SettingsSection.scoringRules:
        return const ScoringRulesView();
      case SettingsSection.courseSchedule:
        return CourseScheduleManagementView(
          onShowCourseDialog: ({Map<String, dynamic>? schedule}) =>
              showCourseScheduleDialog(context, schedule: schedule),
        );
      case SettingsSection.period:
        return const PeriodManagementView();
      case SettingsSection.usbKey:
        return UsbKeyManagementView(
          onWriteKey: () => showWriteKeyDialog(context),
          onRenameKey: (int id, String label) =>
              showRenameKeyDialog(context, id, label),
          onDeleteKey: (int id) => confirmDeleteKey(context, id),
          onVerifyPinForUsbActions: () async => verifyPinForUsbActions(context),
        );
      case SettingsSection.personalization:
        return const PersonalizationView();
      case SettingsSection.system:
        return const SystemSettingsView();
    }
  }

  String _titleOf(SettingsSection section) {
    switch (section) {
      case SettingsSection.group:
        return '分组管理';
      case SettingsSection.student:
        return '学生管理';
      case SettingsSection.scoreItems:
        return '预设评分项';
      case SettingsSection.scoringRules:
        return '计分规则';
      case SettingsSection.courseSchedule:
        return '课程表管理';
      case SettingsSection.period:
        return '评分周期';
      case SettingsSection.usbKey:
        return '物理密钥管理';
      case SettingsSection.personalization:
        return '个性化';
      case SettingsSection.system:
        return '系统设置';
    }
  }
}
