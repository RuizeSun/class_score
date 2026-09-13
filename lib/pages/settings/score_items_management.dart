import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/score_item.dart';
import '../../providers/score_item_provider.dart';
import '../../providers/auth_provider.dart';
import 'settings_common.dart';

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsToolbar(
          children: [
            FilledButton.icon(
              onPressed: () => onShowItemDialog(),
              icon: const Icon(Icons.add),
              label: const Text('添加评分项'),
            ),
          ],
        ),
        Expanded(
          child: items.isEmpty
              ? const SettingsEmptyState(
                  icon: Icons.list_alt_outlined,
                  message: '暂无预设评分项',
                  hint: '点击上方“添加评分项”创建第一个评分项',
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final item = items[i];
                    return ListTile(
                      leading: const Icon(Icons.list_alt_outlined),
                      title: Text(item.name),
                      subtitle: Text(
                        '${item.defaultScore.toStringAsFixed(1)} 分'
                        '${item.description.isNotEmpty ? '  •  ${item.description}' : ''}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit),
                            onPressed: () => onShowItemDialog(item: item),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete),
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
        ),
      ],
    );
  }
}
