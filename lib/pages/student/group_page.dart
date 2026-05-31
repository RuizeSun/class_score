import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/group_provider.dart';
import '../../models/group.dart';
import '../../providers/auth_provider.dart';
import '../settings/group_management.dart'
    show showGroupDialog, showGroupMembersWithBatch, GroupManagementView;

class GroupPage extends StatefulWidget {
  const GroupPage({super.key});

  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GroupProvider>().loadGroups();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('分组管理')),
      body: GroupManagementView(
        onShowGroupDialog: ({Group? group}) =>
            showGroupDialog(context, group: group),
        onShowGroupMembers: (Group group) =>
            showGroupMembersWithBatch(context, group),
      ),
      floatingActionButton: context.watch<AuthProvider>().isUnlocked
          ? FloatingActionButton(
              onPressed: () => showGroupDialog(context),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
