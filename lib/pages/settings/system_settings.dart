import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../providers/auth_provider.dart';
import '../../providers/group_provider.dart';
import '../../providers/student_provider.dart';
import '../../providers/score_item_provider.dart';
import '../../services/backup_service.dart';
import 'pin_dialogs.dart';

/// System settings card widget for use in SettingsHubPage.
class SystemSettingsCard extends StatefulWidget {
  const SystemSettingsCard({super.key});

  @override
  State<SystemSettingsCard> createState() => _SystemSettingsCardState();
}

class _SystemSettingsCardState extends State<SystemSettingsCard> {
  String _version = '加载中...';
  String _buildNumber = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      setState(() {
        _version = packageInfo.version;
        _buildNumber = packageInfo.buildNumber;
      });
    } catch (e) {
      setState(() {
        _version = '获取失败';
        _buildNumber = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '系统设置',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('导出数据库'),
              onTap: () => exportDatabase(context),
            ),
            ListTile(
              leading: const Icon(Icons.upload),
              title: const Text('导入数据库（覆盖）'),
              onTap: () => importDatabase(context),
            ),
            ListTile(
              leading: const Icon(Icons.table_chart),
              title: const Text('导出积分为表格'),
              onTap: () => exportScores(context),
            ),
            ListTile(
              leading: const Icon(Icons.clear_all),
              title: const Text('清除全部评分记录'),
              onTap: () => clearAllScores(context),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('重置数据库'),
              onTap: () => resetDatabase(context),
            ),
            ListTile(
              leading: const Icon(Icons.settings_backup_restore),
              title: const Text('重置全部设置（数据库和设置）'),
              onTap: () => resetAllSettings(context),
            ),
            const Divider(),
            Row(
              children: [
                const Icon(Icons.info_outline, size: 20),
                const SizedBox(width: 12),
                Text(
                  '版本号：$_version',
                  style: const TextStyle(color: Colors.grey),
                ),
                if (_buildNumber.isNotEmpty) ...[
                  const Text('  |  ', style: TextStyle(color: Colors.grey)),
                  Text(
                    'build $_buildNumber',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> exportDatabase(BuildContext context) async {
  final auth = context.read<AuthProvider>();
  if (!auth.isUnlocked) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('请先解锁后再导出数据库')));
    return;
  }
  try {
    final path = await BackupService.instance.createBackup();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('备份已创建: $path')));
  } catch (e) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
  }
}

Future<void> importDatabase(BuildContext context) async {
  await showPinDialog(context, (pin) async {
    final auth = context.read<AuthProvider>();
    if (!auth.verifyPin(pin)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PIN 验证失败')));
      return;
    }
    // 使用文件选择器让用户挑选本地 JSON 文件
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) {
      // 用户取消选择
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未选择文件')));
      return;
    }
    final path = result.files.single.path;
    if (path == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('文件路径无效')));
      return;
    }
    final jsonStr = await File(path).readAsString();
    final success = await BackupService.instance.importFromJson(jsonStr);
    if (success) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导入成功')));
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导入失败')));
    }
  });
}

Future<void> exportScores(BuildContext context) async {
  await showPinDialog(context, (pin) async {
    final auth = context.read<AuthProvider>();
    if (!auth.verifyPin(pin)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PIN 验证失败')));
      return;
    }
    try {
      // 获取 JSON 数据并转换为 CSV 表格
      final jsonStr = await BackupService.instance.exportToJson();
      final Map<String, dynamic> data =
          jsonDecode(jsonStr) as Map<String, dynamic>;
      final List<dynamic> records =
          data['score_records'] as List<dynamic>? ?? [];
      // 构建 CSV 内容，使用第一条记录的键作为表头
      final StringBuffer csvBuffer = StringBuffer();
      if (records.isNotEmpty) {
        final first = records.first as Map<String, dynamic>;
        final headers = first.keys.where((k) => k != 'id').toList();
        csvBuffer.writeln(headers.join(','));
        for (final rec in records) {
          final map = rec as Map<String, dynamic>;
          final row = headers.map((h) => '${map[h] ?? ''}').join(',');
          csvBuffer.writeln(row);
        }
      }
      // 将 CSV 保存为文件，文件名包含时间戳
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final fileName = 'scores_$timestamp.csv';
      await BackupService.instance.ensureBackupDir();
      final filePath = p.join(BackupService.instance.backupDir, fileName);
      final file = File(filePath);
      await file.writeAsString(csvBuffer.toString());
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('积分已导出为表格至 $filePath')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出积分失败: $e')));
    }
  });
}

/// 清除全部评分记录（需要验证PIN）
Future<void> clearAllScores(BuildContext context) async {
  // 先让用户确认操作
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('确认清除'),
      content: const Text('确定要清除所有评分记录吗？此操作不可恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('清除'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  await showPinDialog(context, (pin) async {
    final auth = context.read<AuthProvider>();
    if (!auth.verifyPin(pin)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PIN 验证失败')));
      return;
    }
    await BackupService.instance.resetScoreRecords();
    // 清除评分记录后需要刷新 ScoreProvider 的缓存数据
    await context.read<ScoreItemProvider>().loadItems();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('全部评分记录已清除')));
  });
}

Future<void> resetDatabase(BuildContext context) async {
  await showPinDialog(context, (pin) async {
    final auth = context.read<AuthProvider>();
    if (!auth.verifyPin(pin)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PIN 验证失败')));
      return;
    }
    await BackupService.instance.resetAll();
    // 重置数据库后需要刷新所有 Provider 的缓存数据
    await Future.wait([
      context.read<GroupProvider>().loadGroups(),
      context.read<StudentProvider>().loadStudents(),
      context.read<ScoreItemProvider>().loadItems(),
    ]);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('数据库已重置')));
  });
}

Future<void> resetAllSettings(BuildContext context) async {
  await showPinDialog(context, (pin) async {
    final auth = context.read<AuthProvider>();
    if (!auth.verifyPin(pin)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PIN 验证失败')));
      return;
    }
    await BackupService.instance.resetAll();
    await BackupService.instance.clearAllBackups();
    // 重置全部设置后需要刷新所有 Provider 的缓存数据
    await Future.wait([
      context.read<GroupProvider>().loadGroups(),
      context.read<StudentProvider>().loadStudents(),
      context.read<ScoreItemProvider>().loadItems(),
    ]);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('全部设置已重置')));
  });
}
