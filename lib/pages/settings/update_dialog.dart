import 'package:flutter/material.dart';

import '../../services/update_service.dart';
import '../../widgets/glass_buttons.dart';

/// 弹出「发现新版本」对话框。
///
/// 确认后下载 release.zip（带进度），完成后自动解压、退出并重启安装
/// （安装由独立 PowerShell 脚本完成，见 [UpdateService.installUpdate]）。
/// [update] 由调用方先通过 [UpdateService.checkForUpdate] 取得并确认有新版。
Future<void> showUpdateAvailableDialog(
  BuildContext context,
  UpdateCheckResult update,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(update: update),
  );
}

enum _UpdatePhase { confirm, downloading, installing, error }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.update});

  final UpdateCheckResult update;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _UpdatePhase _phase = _UpdatePhase.confirm;
  double? _progress; // 0-1；null = 总大小未知，走不定进度
  int _receivedBytes = 0;
  int? _totalBytes;
  String? _error;

  bool get _busy =>
      _phase == _UpdatePhase.downloading || _phase == _UpdatePhase.installing;

  Future<void> _startUpdate() async {
    setState(() {
      _phase = _UpdatePhase.downloading;
      _progress = null;
      _receivedBytes = 0;
      _totalBytes =
          widget.update.assetSizeBytes > 0 ? widget.update.assetSizeBytes : null;
    });
    try {
      // 冗余保险：动程序文件之前先给数据库留一份一致性快照
      await UpdateService.createPreUpdateBackup();
      final zip = await UpdateService.instance.downloadRelease(
        widget.update,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = received;
            _totalBytes = total;
            _progress = (total == null || total <= 0) ? null : received / total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _phase = _UpdatePhase.installing);
      // 成功时该方法内部会拉起更新脚本并 exit(0)，不会走到这里
      await UpdateService.instance.installUpdate(zip);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdatePhase.error;
        _error = error.toString();
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return bytes.toString() + ' B';
    final kb = bytes / 1024;
    if (kb < 1024) return kb.toStringAsFixed(0) + ' KB';
    return (kb / 1024).toStringAsFixed(1) + ' MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final update = widget.update;
    final notes = update.releaseNotes.trim();

    return AlertDialog(
      title: const Text('发现新版本'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前版本：v' + update.currentVersion,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              '最新版本：v' + update.latestVersion + '（' + update.tagName + '）',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (update.sourceLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '来源：' + update.sourceLabel,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: SelectableText(
                    notes,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            _buildPhaseArea(theme),
          ],
        ),
      ),
      actions: [
        GlassActionButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('暂不更新'),
        ),
        if (_phase == _UpdatePhase.confirm || _phase == _UpdatePhase.error)
          GlassActionButton(
            onPressed: _startUpdate,
            variant: GlassActionVariant.prominent,
            child: Text(_phase == _UpdatePhase.error ? '重试' : '立即更新'),
          ),
      ],
    );
  }

  /// 弹窗底部随阶段变化的一小块状态区。
  Widget _buildPhaseArea(ThemeData theme) {
    switch (_phase) {
      case _UpdatePhase.confirm:
        return Text(
          '更新将自动下载并安装，完成后应用会自动重启。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        );
      case _UpdatePhase.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text(
              _progress == null
                  ? '已下载 ' + _formatBytes(_receivedBytes)
                  : '已下载 ' + _formatBytes(_receivedBytes) + ' / ' +
                      _formatBytes(_totalBytes ?? 0) +
                      '（' + (_progress! * 100).toStringAsFixed(0) + '%）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        );
      case _UpdatePhase.installing:
        return Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '下载完成，正在准备安装，应用即将重启…',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        );
      case _UpdatePhase.error:
        return Text(
          '更新失败：' + (_error ?? ''),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.error),
        );
    }
  }
}
