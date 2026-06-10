import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';

/// Show dialog to write a USB key.
void showWriteKeyDialog(BuildContext context) {
  String? selectedDrive;
  String label = '';

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        return FutureBuilder<List<String>>(
          future: context.read<AuthProvider>().getAvailableUsbDrives(),
          builder: (ctx, snapshot) {
            final drives = snapshot.data ?? [];
            return AlertDialog(
              title: const Text('写入密钥到 U 盘'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selectedDrive,
                    decoration: const InputDecoration(
                      labelText: '选择 U 盘驱动器',
                      border: OutlineInputBorder(),
                    ),
                    items: drives.isEmpty
                        ? [
                            const DropdownMenuItem(
                              value: null,
                              child: Text('未检测到 U 盘'),
                            ),
                          ]
                        : drives
                              .map(
                                (d) =>
                                    DropdownMenuItem(value: d, child: Text(d)),
                              )
                              .toList(),
                    onChanged: (v) => setDialogState(() => selectedDrive = v),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: '密钥名称（可选）',
                      border: OutlineInputBorder(),
                      hintText: '如：金士顿 U 盘',
                    ),
                    onChanged: (v) => label = v,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: selectedDrive == null
                      ? null
                      : () async {
                          final auth = context.read<AuthProvider>();
                          final success = await auth.writeKeyToUsb(
                            selectedDrive!,
                            label: label.isEmpty ? null : label,
                          );
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            if (success) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('密钥写入成功')),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(auth.errorMessage ?? '写入失败'),
                                ),
                              );
                            }
                          }
                        },
                  child: const Text('写入'),
                ),
              ],
            );
          },
        );
      },
    ),
  );
}

/// Show dialog to rename a USB key.
void showRenameKeyDialog(BuildContext context, int id, String currentLabel) {
  final controller = TextEditingController(text: currentLabel);
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重命名密钥'),
      content: TextField(
        controller: controller,
        decoration: const InputDecoration(
          labelText: '密钥名称',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final newLabel = controller.text.trim();
            if (newLabel.isNotEmpty) {
              context.read<AuthProvider>().renameUsbKey(id, newLabel);
              Navigator.pop(ctx);
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

/// Show dialog to confirm deletion of a USB key.
void confirmDeleteKey(BuildContext context, int id) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('确认删除'),
      content: const Text('确定删除此密钥记录吗？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            context.read<AuthProvider>().deleteUsbKey(id);
            Navigator.pop(ctx);
          },
          child: const Text('删除'),
        ),
      ],
    ),
  );
}

/// 可嵌入 SettingsHubPage 的密钥管理视图（不包含 Scaffold/AppBar）。
class UsbKeyManagementView extends StatelessWidget {
  const UsbKeyManagementView({
    super.key,
    required this.onWriteKey,
    required this.onRenameKey,
    required this.onDeleteKey,
    required this.isUnlocked,
    this.onVerifyPinForUsbActions,
  });

  final VoidCallback onWriteKey;
  final void Function(int id, String currentLabel) onRenameKey;
  final void Function(int id) onDeleteKey;
  final bool isUnlocked;

  /// When provided, this callback is invoked when USB-key unlock requires PIN
  /// verification before performing sensitive actions (write, rename, delete).
  final Future<bool> Function()? onVerifyPinForUsbActions;

  /// Check if USB actions require PIN verification.
  /// Returns true if the user is unlocked via USB and needs to verify PIN.
  bool _needsPinVerification(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return auth.isUnlocked && auth.isUnlockedByUsb && !auth.isUnlockedByManual;
  }

  @override
  Widget build(BuildContext context) {
    final keys = context.watch<AuthProvider>().usbKeys;
    final needsPin = _needsPinVerification(context);

    return Stack(
      children: [
        keys.isEmpty
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.usb, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('暂无已注册的 U 盘密钥'),
                    SizedBox(height: 8),
                    Text('解锁后可管理密钥', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: keys.length,
                itemBuilder: (_, i) {
                  final key = keys[i];
                  return ListTile(
                    leading: const Icon(Icons.usb),
                    title: Text(key['label'] as String? ?? ''),
                    subtitle: Text(
                      '创建于 ${(key['created_at'] as String).replaceFirst('T', ' ').substring(0, 19)}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit),
                          tooltip: '重命名',
                          onPressed: isUnlocked
                              ? () async {
                                  if (needsPin &&
                                      onVerifyPinForUsbActions != null) {
                                    final verified =
                                        await onVerifyPinForUsbActions!();
                                    if (!verified) return;
                                  }
                                  onRenameKey(
                                    key['id'] as int,
                                    key['label'] as String? ?? '',
                                  );
                                }
                              : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          tooltip: '删除密钥',
                          onPressed: isUnlocked
                              ? () async {
                                  if (needsPin &&
                                      onVerifyPinForUsbActions != null) {
                                    final verified =
                                        await onVerifyPinForUsbActions!();
                                    if (!verified) return;
                                  }
                                  onDeleteKey(key['id'] as int);
                                }
                              : null,
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
              heroTag: 'usb_key_fab',
              onPressed: () async {
                if (needsPin && onVerifyPinForUsbActions != null) {
                  final verified = await onVerifyPinForUsbActions!();
                  if (!verified) return;
                }
                onWriteKey();
              },
              child: const Icon(Icons.add),
            ),
          ),
      ],
    );
  }
}
