import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../settings/usb_key_management.dart'
    show
        showWriteKeyDialog,
        showRenameKeyDialog,
        confirmDeleteKey,
        UsbKeyManagementView;
import '../settings/pin_dialogs.dart' show verifyPinForUsbActions;

class UsbKeyPage extends StatefulWidget {
  const UsbKeyPage({super.key});

  @override
  State<UsbKeyPage> createState() => _UsbKeyPageState();
}

class _UsbKeyPageState extends State<UsbKeyPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().loadUsbKeys();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isUnlocked = context.watch<AuthProvider>().isUnlocked;
    return Scaffold(
      appBar: AppBar(title: const Text('物理密钥管理')),
      body: UsbKeyManagementView(
        onWriteKey: () => showWriteKeyDialog(context),
        onRenameKey: (int id, String label) =>
            showRenameKeyDialog(context, id, label),
        onDeleteKey: (int id) => confirmDeleteKey(context, id),
        isUnlocked: isUnlocked,
        onVerifyPinForUsbActions: () async => verifyPinForUsbActions(context),
      ),
      floatingActionButton: isUnlocked
          ? FloatingActionButton(
              onPressed: () => showWriteKeyDialog(context),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
