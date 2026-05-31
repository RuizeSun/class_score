import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/score_item.dart';
import '../../providers/score_item_provider.dart';
import '../../providers/auth_provider.dart';
import '../settings/score_items_management.dart'
    show showScoreItemDialog, ScoreItemsManagementView;

class ScoreItemsPage extends StatefulWidget {
  const ScoreItemsPage({super.key});

  @override
  State<ScoreItemsPage> createState() => _ScoreItemsPageState();
}

class _ScoreItemsPageState extends State<ScoreItemsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ScoreItemProvider>().loadItems();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('预设评分项')),
      body: ScoreItemsManagementView(
        onShowItemDialog: ({ScoreItem? item}) =>
            showScoreItemDialog(context, item: item),
      ),
      floatingActionButton: context.watch<AuthProvider>().isUnlocked
          ? FloatingActionButton(
              onPressed: () => showScoreItemDialog(context),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
