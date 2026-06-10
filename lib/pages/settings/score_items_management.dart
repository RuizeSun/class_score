import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/score_item.dart';
import '../../providers/score_item_provider.dart';
import '../../providers/auth_provider.dart';

/// Show dialog to add or edit a score item.
void showScoreItemDialog(BuildContext context, {ScoreItem? item}) {
  final nameController = TextEditingController(text: item?.name ?? '');
  final scoreController = TextEditingController(
    text: item?.defaultScore.toString() ?? '',
  );
  final descController = TextEditingController(text: item?.description ?? '');

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(item == null ? '添加评分项' : '编辑评分项'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameController,
            decoration: const InputDecoration(labelText: '评分项名称'),
            autofocus: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: scoreController,
            decoration: const InputDecoration(
              labelText: '默认分值',
              hintText: '支持小数，如 -1 或 +0.5',
            ),
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: descController,
            decoration: const InputDecoration(labelText: '描述（可选）'),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final name = nameController.text.trim();
            final scoreText = scoreController.text.trim();
            if (name.isEmpty || scoreText.isEmpty) return;
            final score = double.tryParse(scoreText);
            if (score == null) return;

            final newItem = ScoreItem(
              name: name,
              defaultScore: score,
              description: descController.text.trim(),
            );
            if (item == null) {
              context.read<ScoreItemProvider>().addItem(newItem);
            } else {
              context.read<ScoreItemProvider>().updateItem(item.id!, newItem);
            }
            Navigator.pop(ctx);
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

class ScoreItemsManagementView extends StatelessWidget {
  const ScoreItemsManagementView({super.key, required this.onShowItemDialog});

  final void Function({ScoreItem? item}) onShowItemDialog;

  @override
  Widget build(BuildContext context) {
    final items = context.watch<ScoreItemProvider>().items;
    final isUnlocked = context.watch<AuthProvider>().isUnlocked;

    return Stack(
      children: [
        items.isEmpty
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.list_alt, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('暂无预设评分项'),
                    SizedBox(height: 8),
                    Text('点击右下角添加', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final item = items[i];
                  return ListTile(
                    title: Text(item.name),
                    subtitle: Text(
                      '${item.defaultScore.toStringAsFixed(1)} 分'
                      '${item.description.isNotEmpty ? '  •  ${item.description}' : ''}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isUnlocked)
                          IconButton(
                            icon: const Icon(Icons.edit, size: 20),
                            onPressed: () => onShowItemDialog(item: item),
                          ),
                        if (isUnlocked)
                          IconButton(
                            icon: const Icon(Icons.delete, size: 20),
                            onPressed: () {
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('确认删除'),
                                  content: Text('确定删除评分项"${item.name}"吗？'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx),
                                      child: const Text('取消'),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        context
                                            .read<ScoreItemProvider>()
                                            .deleteItem(item.id!);
                                        Navigator.pop(ctx);
                                      },
                                      child: const Text('删除'),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  );
                },
              ),
        if (isUnlocked)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              heroTag: 'score_item_fab',
              onPressed: () => onShowItemDialog(),
              child: const Icon(Icons.add),
            ),
          ),
      ],
    );
  }
}
