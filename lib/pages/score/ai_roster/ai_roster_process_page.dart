import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../models/ai_selection_rule.dart';
import '../../../models/student.dart';
import '../../../services/ai_roster_service.dart';
import '../../../services/roster_matcher.dart';
import '../../../widgets/glass_buttons.dart';
import '../../../widgets/glass_controls.dart';
import '../../../widgets/student_name_text.dart';
import '../../settings/ai_provider_settings.dart';

/// 花名册处理页：左侧显示裁剪后的图像，右侧配置「怎样选中学生」。
///
/// 采用后通过 Navigator.pop 回传学生 id 集合。
class AiRosterProcessPage extends StatefulWidget {
  const AiRosterProcessPage({
    super.key,
    required this.imageBytes,
    required this.candidates,
  });

  final Uint8List imageBytes;

  /// 候选学生（评分页当前筛选范围内）。
  final List<Student> candidates;

  @override
  State<AiRosterProcessPage> createState() => _AiRosterProcessPageState();
}

class _AiRosterProcessPageState extends State<AiRosterProcessPage> {
  final Set<RosterMark> _marks = {RosterMark.check};
  ScoreThreshold _threshold = ScoreThreshold.none;
  final TextEditingController _thresholdController = TextEditingController(
    text: '60',
  );
  final TextEditingController _customController = TextEditingController();
  final TextEditingController _followUpController = TextEditingController();

  final double _splitRatio = 0.5;
  bool _running = false;
  String? _error;

  /// 上一次识别结果。
  RosterMatchResult? _result;
  String _layout = '';
  int _round = 0;

  /// 用户在确认界面手动勾选的（来自 uncertain 的候选）。
  final Set<int> _manualIds = {};

  /// 用户取消勾选的已匹配学生。
  final Set<int> _excluded = {};

  @override
  void initState() {
    super.initState();
    AiRosterService.instance.resetHistory();
  }

  @override
  void dispose() {
    _thresholdController.dispose();
    _customController.dispose();
    _followUpController.dispose();
    super.dispose();
  }

  AiSelectionRule get _rule => AiSelectionRule(
    marks: Set<RosterMark>.from(_marks),
    scoreThreshold: _threshold,
    scoreValue: double.tryParse(_thresholdController.text.trim()) ?? 60,
    customInstruction: _customController.text.trim(),
  );

  List<String> get _candidateLines => widget.candidates
      .map(
        (s) =>
            (s.studentNumber.isEmpty ? s.name : '${s.studentNumber} ${s.name}'),
      )
      .toList();

  Future<void> _start({String followUp = ''}) async {
    if (_running) return;
    if (_marks.isEmpty && _threshold == ScoreThreshold.none) {
      _snack('请至少选择一种选中条件');
      return;
    }
    if (widget.candidates.isEmpty) {
      _snack('当前没有学生，请先添加学生');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final resp = await AiRosterService.instance.recognize(
        imageBytes: widget.imageBytes,
        rule: _rule,
        candidateLines: _candidateLines,
        followUp: followUp,
      );
      final hits = resp.entries.where((e) => e.matchesRule(_rule)).toList();
      final matched = matchEntries(hits, widget.candidates);
      if (!mounted) return;
      setState(() {
        _result = matched;
        _layout = resp.layout;
        _round += 1;
        _manualIds.clear();
        _excluded.clear();
      });
    } on AiServiceException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '识别失败：$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Set<int> get _selectedIds {
    final base = <int>{...?_result?.matchedIds};
    base.removeAll(_excluded);
    base.addAll(_manualIds);
    return base;
  }

  String _nameOf(int id) {
    for (final s in widget.candidates) {
      if (s.id == id) return s.name;
    }
    return '#$id';
  }

  String _numberOf(int id) {
    for (final s in widget.candidates) {
      if (s.id == id) return s.studentNumber;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 选学生'),
        actions: [
          GlassIconAction(
            tooltip: 'AI 服务商设置',
            icon: const Icon(Icons.settings_outlined),
            size: 40,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiProviderSettingsPage()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _result == null ? _buildSplit() : _buildResultAndSplit(),
          ),
        ],
      ),
    );
  }

  Widget _buildSplit() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: (_splitRatio * 100).round(), child: _buildImagePane()),
          const SizedBox(width: 12),
          Expanded(
            flex: ((1 - _splitRatio) * 100).round(),
            child: _buildSettingsPane(),
          ),
        ],
      ),
    );
  }

  Widget _buildResultAndSplit() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: (_splitRatio * 100).round(), child: _buildImagePane()),
          const SizedBox(width: 12),
          Expanded(
            flex: ((1 - _splitRatio) * 100).round(),
            child: _buildResultPane(),
          ),
        ],
      ),
    );
  }

  Widget _buildImagePane() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
        ),
      ),
    );
  }

  Widget _buildSettingsPane() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '选择学生的条件',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            '可多选，互斥项会自动取消',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _markChip(RosterMark.check, '打勾 ✓'),
              _markChip(RosterMark.cross, '打叉 ×'),
              _markChip(RosterMark.triangle, '三角形 △'),
              _markChip(RosterMark.anyMark, '有手写内容'),
              _markChip(RosterMark.blank, '空白（无标记）'),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            '分数条件（可选）',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              GlassSegmentedChoice<ScoreThreshold>(
                selected: _threshold,
                onChanged: (value) => setState(() => _threshold = value),
                options: const [
                  GlassSegmentedOption(value: ScoreThreshold.none, label: '不用'),
                  GlassSegmentedOption(
                    value: ScoreThreshold.atLeast,
                    label: '≥',
                  ),
                  GlassSegmentedOption(value: ScoreThreshold.below, label: '<'),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _thresholdController,
                  enabled: _threshold != ScoreThreshold.none,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '分数',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            '自定义条件（可选）',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _customController,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '例如：只选订正过的学生',
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Text(
                _error!,
                style: TextStyle(color: Colors.red.shade800, fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            height: 46,
            child: GlassActionButton.icon(
              onPressed: _running ? null : () => _start(),
              icon: _running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_running ? 'AI 正在识别…' : '开始识别'),
              height: 46,
              padding: EdgeInsets.zero,
              variant: GlassActionVariant.prominent,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '识别范围：${widget.candidates.length} 名学生',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _markChip(RosterMark mark, String label) {
    final selected = _marks.contains(mark);
    return GlassChipControl(
      label: label,
      selected: selected,
      onTap: () {
        setState(() {
          if (!selected) {
            final conflicts = AiSelectionRule.conflictsWhenSelecting(
              _marks.map((m) => 'mark:${m.name}').toSet(),
              'mark:${mark.name}',
            );
            for (final c in conflicts) {
              final name = c.split(':').last;
              _marks.removeWhere((m) => m.name == name);
            }
            _marks.add(mark);
          } else {
            _marks.remove(mark);
          }
        });
      },
    );
  }

  Widget _buildResultPane() {
    final sel = _selectedIds;
    final uncertain = _result?.uncertain ?? const <RosterUncertainItem>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.auto_awesome, size: 18),
            const SizedBox(width: 6),
            Text(
              'AI 识别结果（第 $_round 轮）',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const Spacer(),
            GlassActionButton(
              onPressed: _running ? null : () => setState(() => _result = null),
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              fontSize: 13,
              child: const Text('重新设置'),
            ),
          ],
        ),
        if (_layout.isNotEmpty)
          Text(
            '版式：$_layout',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: sel.isEmpty ? Colors.orange.shade50 : Colors.green.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            sel.isEmpty ? '没有符合条件的学生' : '将选中 ${sel.length} 名学生',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: sel.isEmpty
                  ? Colors.orange.shade800
                  : Colors.green.shade800,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (sel.isNotEmpty) ...[
                  const Text(
                    '已选中（可取消）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: sel.map((id) {
                      return GlassChipControl(
                        label: _nameOf(id),
                        selected: true,
                        onDeleted: () {
                          setState(() {
                            _manualIds.remove(id);
                            _excluded.add(id);
                          });
                        },
                        child: StudentNameText(
                          name: _nameOf(id),
                          studentNumber: _numberOf(id),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                ],
                if (uncertain.isNotEmpty) ...[
                  const Text(
                    '无法确定（请手动选择）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  ...uncertain.map((u) {
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              [
                                u.printedNumber,
                                u.printedName,
                              ].where((s) => s.isNotEmpty).join(' '),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              u.reason,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade700,
                              ),
                            ),
                            if (u.candidates.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                children: u.candidates.map((s) {
                                  final picked = _manualIds.contains(s.id);
                                  return GlassChipControl(
                                    label: s.name,
                                    selected: picked,
                                    onTap: () => setState(() {
                                      if (!picked) {
                                        _manualIds.add(s.id!);
                                      } else {
                                        _manualIds.remove(s.id);
                                      }
                                    }),
                                    child: StudentNameText(
                                      name: s.name,
                                      studentNumber: s.studentNumber,
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 16),
        Row(
          children: [
            Expanded(
              child: GlassActionButton.icon(
                onPressed: _running ? null : _reject,
                icon: const Icon(Icons.close),
                label: const Text('不采用'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GlassActionButton.icon(
                onPressed: _running || sel.isEmpty
                    ? null
                    : () => Navigator.pop(context, sel),
                icon: const Icon(Icons.check),
                label: const Text('采用'),
                variant: GlassActionVariant.prominent,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _reject() async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('不采用这次结果'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'give_up'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.exit_to_app, size: 20),
                  SizedBox(width: 10),
                  Expanded(child: Text('放弃本次 AI 识别，返回评分页手动选择')),
                ],
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'refine'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.edit_note, size: 20),
                  SizedBox(width: 10),
                  Expanded(child: Text('提出进一步要求，让 AI 重新识别')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'give_up') {
      Navigator.pop(context);
    } else if (action == 'refine') {
      await _showRefineDialog();
    }
  }

  Future<void> _showRefineDialog() async {
    _followUpController.clear();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('提出进一步要求'),
        content: TextField(
          controller: _followUpController,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '例如：只选第 2 列的标记；三角也算选中；忽略第一行标题',
          ),
        ),
        actions: [
          GlassActionButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          GlassActionButton(
            onPressed: () =>
                Navigator.pop(ctx, _followUpController.text.trim()),
            variant: GlassActionVariant.prominent,
            child: const Text('重新识别'),
          ),
        ],
      ),
    );
    if (!mounted || text == null || text.isEmpty) return;
    await _start(followUp: text);
  }
}
