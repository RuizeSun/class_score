import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/pin_pad.dart';

/// Verify PIN when USB-key unlock requires PIN for sensitive actions.
/// Returns true if PIN is verified successfully.
Future<bool> verifyPinForUsbActions(BuildContext context) async {
  String pin = '';
  final auth = context.read<AuthProvider>();
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (dialogContext, setState) {
        return AlertDialog(
          title: const Text('验证 PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('通过物理密钥解锁时，修改密钥设置需要验证 PIN。'),
              const SizedBox(height: 16),
              PinPad(
                currentPin: pin,
                onPinChanged: (v) => setState(() => pin = v),
                onConfirm: () async {
                  Navigator.of(dialogContext).pop();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                if (auth.verifyPin(pin)) {
                  Navigator.pop(dialogContext, true);
                } else {
                  Navigator.pop(dialogContext, false);
                }
              },
              child: const Text('确认'),
            ),
          ],
        );
      },
    ),
  );
  if (result == true) {
    return true;
  }
  // Show error only on verification failure
  if (pin.isNotEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('PIN 验证失败')));
  }
  return false;
}

/// Show a PIN input dialog and call [onConfirmed] with the entered PIN.
Future<void> showPinDialog(
  BuildContext context,
  Future<void> Function(String pin) onConfirmed,
) async {
  // The PIN value must persist across rebuilds of the dialog. Declaring it
  // inside the StatefulBuilder caused it to reset to an empty string on each
  // setState call, which prevented the circles from updating. We now keep the
  // variable in the outer scope of the dialog.
  String pin = '';
  await showDialog(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (dialogContext, setState) {
        return AlertDialog(
          title: const Text('请输入 PIN'),
          content: PinPad(
            currentPin: pin,
            onPinChanged: (v) => setState(() => pin = v),
            // Keep the original auto-confirm when PIN length reaches the limit.
            onConfirm: () async {
              Navigator.of(dialogContext).pop();
              await onConfirmed(pin);
            },
          ),
          // Add explicit action buttons so users can confirm even if they
          // haven't filled the full length or prefer a manual confirm.
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await onConfirmed(pin);
              },
              child: const Text('确认'),
            ),
          ],
        );
      },
    ),
  );
}
