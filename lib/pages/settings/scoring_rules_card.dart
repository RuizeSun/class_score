import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/score_provider.dart';

/// 计分规则设置卡片：学生初始分、小组初始分、小组总分计算方式。
class ScoringRulesCard extends StatefulWidget {
  const ScoringRulesCard({super.key});

  @override
  State<ScoringRulesCard> createState() => _ScoringRulesCardState();
}

class _ScoringRulesCardState extends State<ScoringRulesCard> {
  late final TextEditingController _studentInitialController;
  late final TextEditingController _groupInitialController;

  @override
  void initState() {
    super.initState();
    _studentInitialController = TextEditingController();
    _groupInitialController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ScoreProvider>().loadScoreConfig().then((_) {
        if (!mounted) return;
        final p = context.read<ScoreProvider>();
        setState(() {
          _studentInitialController.text =
              _trimNum(p.studentInitialScore.toString());
          _groupInitialController.text =
              _trimNum(p.groupInitialScore.toString());
        });
      });
    });
  }

  @override
  void dispose() {
    _studentInitialController.dispose();
    _groupInitialController.dispose();
    super.dispose();
  }

  String _trimNum(String s) {
    if (s.endsWith('.0')) return s.substring(0, s.length - 2);
    return s;
  }

  Future<void> _saveInitialScores() async {
    final p = context.read<ScoreProvider>();
    final studentVal =
        double.tryParse(_studentInitialController.text.trim()) ?? 0.0;
    final groupVal = double.tryParse(_groupInitialController.text.trim()) ?? 0.0;
    await p.setStudentInitialScore(studentVal);
    await p.setGroupInitialScore(groupVal);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('初始分已保存'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ScoreProvider>();
    final mode = p.groupScoreMode;

    return Card(
      margin: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.rule,
                  size: 28,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                const Text(
                  '计分规则',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '统一设置初始分与小组总分计算方式，对所有学生/小组生效。',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),

            const Text(
              '初始分',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '学生初始分计入个人总分，并参与小组“学生得分总和”与“人均得分”计算。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _studentInitialController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '学生初始分',
                      border: OutlineInputBorder(),
                      hintText: '默认 0',
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _groupInitialController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '小组初始分',
                      border: OutlineInputBorder(),
                      hintText: '默认 0（小组自定初始分模式生效）',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: ElevatedButton.icon(
                onPressed: _saveInitialScores,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存初始分'),
              ),
            ),
            const SizedBox(height: 24),
            const Divider(),

            const Text(
              '小组总分计算方式',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'sum',
                    label: Text('学生得分总和'),
                    icon: Icon(Icons.groups),
                  ),
                  ButtonSegment(
                    value: 'group_init',
                    label: Text('小组自定初始分'),
                    icon: Icon(Icons.flag),
                  ),
                  ButtonSegment(
                    value: 'avg',
                    label: Text('人均得分'),
                    icon: Icon(Icons.equalizer),
                  ),
                ],
                selected: {mode},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  context.read<ScoreProvider>().setGroupScoreMode(
                        selection.first,
                      );
                },
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _formulaRow(
                    '学生得分总和',
                    '组内学生初始分之和 + 成员当期积分变动总和',
                  ),
                  const SizedBox(height: 8),
                  _formulaRow(
                    '小组自定初始分',
                    '小组初始分 + 成员当期积分变动总和',
                  ),
                  const SizedBox(height: 8),
                  _formulaRow(
                    '人均得分',
                    '（组内学生初始分之和 + 成员当期积分变动总和）÷ 组人数',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _formulaRow(String name, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 5),
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: Colors.grey,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$name：$desc',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }
}
