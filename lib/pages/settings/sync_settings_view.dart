import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/sync_provider.dart';
import '../../sync/sync_engine.dart';
import 'settings_common.dart';

/// 设置 → 同步服务。
///
/// 这一页承担三件事：配对、看状态、手动补一次同步。
/// 刻意不做"冲突列表"——冲突（同一行两端都改）在本应用里几乎只发生在
/// 学生改名/换组这种低频操作上，而 LWW 已经给了确定性答案；
/// 真出问题时看 lastError 与日志比看一个列表更快。
///
/// **注意**：页头与滚动由 SettingsHubPage 的 SettingsSectionScaffold 统一提供，
/// 这里只返回内容本身（返回 Column 会嵌套两层 Expanded → 无界高度断言）。
class SyncSettingsView extends StatefulWidget {
  const SyncSettingsView({super.key});

  @override
  State<SyncSettingsView> createState() => _SyncSettingsViewState();
}

class _SyncSettingsViewState extends State<SyncSettingsView> {
  final _urlController = TextEditingController();
  final _codeController = TextEditingController();
  final _caController = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    // 已配对时回显地址（读引擎的内存缓存，不查库、不异步）。
    final url = SyncEngine.instance.serverUrl;
    if (url.isNotEmpty) _urlController.text = url;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _codeController.dispose();
    _caController.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final url = _urlController.text.trim();
    final code = _codeController.text.trim();
    if (url.isEmpty || code.isEmpty) {
      setState(() => _message = '请先填写服务器地址和配对码');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final isHttps = url.toLowerCase().startsWith('https://');
    final error = await context.read<SyncProvider>().pair(
      serverUrl: url,
      code: code,
      caPemPath: isHttps && _caController.text.trim().isNotEmpty
          ? _caController.text.trim()
          : null,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = error ?? '配对成功，已开始同步';
    });
  }

  String _describeChoice(MergeChoice choice) => switch (choice) {
    MergeChoice.merge => '已按合并方式完成首次同步',
    MergeChoice.keepLocal => '已保留本地数据并上传',
    MergeChoice.keepRemote => '已用服务端数据覆盖本地',
  };

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncProvider>();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusCard(sync: sync),
        const SizedBox(height: SettingsLayout.sectionSpacing),
        const SettingsSectionTitle(
          title: '连接',
          subtitle: '服务端启动时控制台会打印监听地址与一次性配对码',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            labelText: '服务器地址',
            hintText: 'http://127.0.0.1:8787',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _codeController,
          decoration: const InputDecoration(
            labelText: '一次性配对码',
            helperText: '每次启动服务端都会生成一个 10 分钟有效的 6 位码',
          ),
        ),
        const SizedBox(height: 12),
        // 只在 https 时有意义：服务端多半是自签名证书，需要显式信任那一张。
        TextField(
          controller: _caController,
          decoration: const InputDecoration(
            labelText: '服务端证书文件（https 时填写）',
            hintText: 'D:\class_score\cert.pem',
            helperText: '自签名证书需要指定；只信任这一张，不是跳过校验',
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _pair,
              icon: const Icon(Icons.link),
              label: Text(_busy ? '配对中…' : '配对'),
            ),
            OutlinedButton.icon(
              onPressed: sync.isConfigured
                  ? () async {
                      await context.read<SyncProvider>().unpair();
                      if (!mounted) return;
                      setState(() => _message = '已解除绑定（本地数据保留）');
                    }
                  : null,
              icon: const Icon(Icons.link_off),
              label: const Text('解除绑定'),
            ),
            // 「立即同步」必须有反馈：syncNow 会在未配对 / 正在跑 / 退避期
            // 三种情况下不做事，之前这些分支都静默 return，用户点完毫无反应。
            OutlinedButton.icon(
              onPressed: sync.isConfigured && !_busy
                  ? () async {
                      setState(() {
                        _busy = true;
                        _message = null;
                      });
                      final error =
                          await context.read<SyncProvider>().syncNow();
                      if (!mounted) return;
                      setState(() {
                        _busy = false;
                        _message = error ?? '同步完成';
                      });
                    }
                  : null,
              icon: const Icon(Icons.sync),
              label: const Text('立即同步'),
            ),
            // 全量对齐与「立即同步」是互补的两条路：前者拉快照（慢、能修复
            // 游标坏掉或本地被还原的情况），后者走增量事件流（快）。
            // 平时不需要点它，放在这里是为了出事时有一个明确的出口。
            OutlinedButton.icon(
              onPressed: sync.isConfigured && !_busy
                  ? () async {
                      setState(() {
                        _busy = true;
                        _message = null;
                      });
                      final error =
                          await context.read<SyncProvider>().bootstrapFromServer();
                      if (!mounted) return;
                      setState(() {
                        _busy = false;
                        _message = error ?? '全量对齐完成';
                      });
                    }
                  : null,
              icon: const Icon(Icons.cloud_download),
              label: const Text('全量对齐'),
            ),
          ],
        ),

        // 两端都有数据时必须让用户选：自动挑一边等于替他决定丢掉哪一边。
        if (sync.needsMergeDecision) ...[
          const SizedBox(height: SettingsLayout.sectionSpacing),
          MergeDecisionPanel(
            preview: sync.mergePreview!,
            busy: sync.initialBusy,
            onChoose: (choice) async {
              setState(() {
                _busy = true;
                _message = null;
              });
              final error = await context.read<SyncProvider>()
                  .resolveInitialSync(choice);
              if (!mounted) return;
              setState(() {
                _busy = false;
                _message = error ?? _describeChoice(choice);
              });
            },
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 16),
          Text(_message!, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: SettingsLayout.sectionSpacing),
        const Divider(height: 1),
        const SizedBox(height: SettingsLayout.sectionSpacing),
        const SettingsSectionTitle(
          title: '说明',
          subtitle: '同步是后台行为，任何时候都不会挡住打分',
        ),
        const SizedBox(height: 8),
        Text(
          '· 本地仍是唯一数据源：断网或服务端关机都不影响任何功能。\n'
          '· 改动先落本地库并排队，联网后自动推送；对端下次上线自动合并。\n'
          '· 删除采用墓碑标记而非物理删除，避免"删了又回来"。\n'
          '· 导入 / 重置属于整库操作，不逐条推送。',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// 状态摘要。
///
/// 用 Container + 边框而不是 Card：设置页统一约定「不再使用卡片」
/// （见 test/settings_layout_test.dart 的断言）。
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.sync});

  final SyncProvider sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = _describe(sync.status);
    final last = sync.lastSuccessAt;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 12, color: color),
              const SizedBox(width: 8),
              Text(label, style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            last == null ? '尚未成功同步' : '上次成功同步：${_format(last)}',
            style: theme.textTheme.bodySmall,
          ),
          if (sync.pendingCount > 0)
            Text(
              '待推送事件：${sync.pendingCount} 条',
              style: theme.textTheme.bodySmall,
            ),
          // 悬挂的占位行：父行迟迟不到留下的空名字行。不会自动清理
          // （自动删可能误删真实数据），但必须让人看得见，否则它以
          // "一个没有名字的学生"的形式永远潜伏在名单里。
          // 有事件被丢弃（服务端逐条拒收 / 本地解不出来）：同步链路是通的，
          // 但那些数据永远到不了对端。必须让人看见，否则就是"看着正常、数据少了"。
          if (sync.droppedEvents > 0)
            Text(
              '已丢弃事件：${sync.droppedEvents} 条（服务端拒收或无法解析，'
              '点「全量对齐」可重新铺平）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          // 应用远端事件失败的条数：这些是**还留在**游标之前的，会继续重试。
          if (sync.rejectedEvents > 0)
            Text(
              '无法应用的远端事件：${sync.rejectedEvents} 条（会在下一轮重试）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          if (sync.orphanPlaceholders > 0)
            Text(
              '异常占位行：${sync.orphanPlaceholders} 行（对端数据不完整，'
              '点「全量对齐」可修复）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          if (sync.lastError != null)
            Text(
              '最近错误：${sync.lastError}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  (String, Color) _describe(SyncStatus status) => switch (status) {
    SyncStatus.disabled => ('未启用', Colors.grey),
    SyncStatus.offline => ('服务端离线（本地照常使用）', Colors.orange),
    SyncStatus.idle => ('已连接', Colors.green),
    SyncStatus.syncing => ('同步中…', Colors.blue),
    SyncStatus.authRequired => ('需要重新配对（凭据失效）', Colors.red),
    SyncStatus.error => ('同步出错', Colors.red),
  };

  String _format(DateTime time) {
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
/// 两端都有数据时，让用户三选一。
///
/// 三个选项的差别不是"实现细节"，而是**会丢什么**，所以文案必须写清楚：
/// - 合并：什么都不丢，代价是可能留下两边重复加了同一条的痕迹；
/// - 保留本地：服务端独有的行会被本地覆盖（内容层面），但行还在；
/// - 保留远端：本地独有的行会被打成本地墓碑（在界面上消失）。
class MergeDecisionPanel extends StatelessWidget {
  const MergeDecisionPanel({
    required this.preview,
    required this.busy,
    required this.onChoose,
  });

  final InitialMergePreview preview;
  final bool busy;
  final ValueChanged<MergeChoice> onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.primary),
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('首次同步：两端都有数据', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '本地 ${preview.localRows} 行 · '
            '服务端 ${preview.remoteRows} 行。\n'
            '这通常是"大屏先用了很久，之后才配了第二台机器"造成的。\n'
            '请选择以哪一边为准——这一步之前不会同步任何数据。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : () => onChoose(MergeChoice.merge),
                icon: const Icon(Icons.merge_type),
                label: const Text('合并（推荐）'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => onChoose(MergeChoice.keepLocal),
                icon: const Icon(Icons.upload),
                label: const Text('保留本地'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => onChoose(MergeChoice.keepRemote),
                icon: const Icon(Icons.download),
                label: const Text('保留远端'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '· 合并：逐行按修改次数裁决，两边都不丢；'
            '若两边各加过同一条，会都留下。\n'
            '· 保留本地：服务端上的行会被本地内容覆盖。\n'
            '· 保留远端：本地独有的行会在界面上消失（墓碑，可在回收站找回）。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
