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
import 'personalization_card.dart';
import 'scoring_rules_card.dart';
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
          item(Icons.usb, '物理密钥', SettingsSection.usbKey),
          const Divider(),
          item(Icons.settings, '系统设置', SettingsSection.system),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final section = _current;
    if (section != SettingsSection.system &&
        section != SettingsSection.personalization) {
      final hasToolbar = section == SettingsSection.student;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Text(
                  _titleOf(section),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (hasToolbar)
                  PopupMenuButton(
                    icon: const Icon(Icons.file_download),
                    tooltip: '导入学生',
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'csv',
                        child: Row(
                          children: [
                            Icon(Icons.file_download_outlined),
                            SizedBox(width: 8),
                            Text('从 CSV 导入'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'excel',
                        child: Row(
                          children: [
                            Icon(Icons.file_download_outlined),
                            SizedBox(width: 8),
                            Text('从 Excel 导入'),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (value) async {
                      if (value == 'csv' || value == 'excel') {
                        await StudentProvider.showImportDialog(context);
                      }
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: _buildSectionActions(context)),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _titleOf(section),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildSectionActions(context),
        ],
      ),
    );
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
        return const ScoringRulesCard();
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
        return const PersonalizationCard();
      case SettingsSection.system:
        return const SystemSettingsCard();
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
