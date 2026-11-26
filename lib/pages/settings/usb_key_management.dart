import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/glass_buttons.dart';
import '../../widgets/glass_controls.dart';
import '../../widgets/glass_inputs.dart';
import 'settings_common.dart';

/// Show dialog to write a USB key.
void showWriteKeyDialog(BuildContext context) {
  String? selectedDrive;
  String label = '';
  // 驱动器枚举只发起一次。
  //
  // 以前 future 写在 FutureBuilder 的参数里，而它位于 StatefulBuilder 内部：
  // 每次 setDialogState（例如选下拉框、输入名称）都会重新枚举一遍驱动器，
  // 同时把「加载中」和「未检测到 U 盘」混为同一种显示。
  final drivesFuture = context.read<AuthProvider>().getAvailableUsbDrives();

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        return FutureBuilder<List<String>>(
          future: drivesFuture,
          builder: (ctx, snapshot) {
            final loading =
                snapshot.connectionState == ConnectionState.waiting;
            final drives = snapshot.data ?? const <String>[];
            return AlertDialog(
              title: const Text('写入密钥到 U 盘'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          ),
                          SizedBox(width: 10),
                          Text('正在检测 U 盘…'),
                        ],
                      ),
                    )
                  else
                    GlassDropdownField<String>(
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
                                  (d) => DropdownMenuItem(
                                    value: d,
                                    child: Text(d),
                                  ),
                                )
                                .toList(),
                      onChanged: (v) =>
                          setDialogState(() => selectedDrive = v),
                    ),
                  const SizedBox(height: 12),
                  GlassInput(
                    label: '密钥名称（可选）',
                    hint: '如：金士顿 U 盘',
                    onChanged: (v) => label = v,
                  ),
                ],
              ),
              actions: [
                GlassActionButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                GlassActionButton(
                  variant: GlassActionVariant.prominent,
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
      content: GlassInput(
        controller: controller,
        label: '密钥名称',
        autofocus: true,
      ),
      actions: [
        GlassActionButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        GlassActionButton(
          variant: GlassActionVariant.prominent,
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
        GlassActionButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        GlassActionButton(
          variant: GlassActionVariant.prominent,
          tintColor: Colors.red.withValues(alpha: 0.55),
          foregroundColor: Colors.white,
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
    this.onVerifyPinForUsbActions,
  });

  final VoidCallback onWriteKey;
  final void Function(int id, String currentLabel) onRenameKey;
  final void Function(int id) onDeleteKey;

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsToolbar(
          children: [
            GlassActionButton.icon(
              onPressed: () async {
                if (needsPin && onVerifyPinForUsbActions != null) {
                  final verified = await onVerifyPinForUsbActions!();
                  if (!verified) return;
                }
                onWriteKey();
              },
              icon: const Icon(Icons.add),
              label: const Text('写入密钥'),
              variant: GlassActionVariant.prominent,
            ),
          ],
        ),
        Expanded(
          child: keys.isEmpty
              ? const SettingsEmptyState(
                  icon: Icons.usb,
                  message: '暂无已注册的 U 盘密钥',
                  hint: '点击上方“写入密钥”注册第一个密钥',
                )
              : ListView.separated(
                  itemCount: keys.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
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
                          GlassIconAction(
                            icon: const Icon(Icons.edit),
                            tooltip: '重命名',
                            size: 36,
                            onPressed: () async {
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
                            },
                          ),
                          GlassIconAction(
                            icon: const Icon(Icons.delete),
                            tooltip: '删除密钥',
                            size: 36,
                            onPressed: () async {
                              if (needsPin &&
                                  onVerifyPinForUsbActions != null) {
                                final verified =
                                    await onVerifyPinForUsbActions!();
                                if (!verified) return;
                              }
                              onDeleteKey(key['id'] as int);
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
