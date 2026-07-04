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
    return Scaffold(
      appBar: AppBar(title: const Text('物理密钥管理')),
      body: UsbKeyManagementView(
        onWriteKey: () => showWriteKeyDialog(context),
        onRenameKey: (int id, String label) =>
            showRenameKeyDialog(context, id, label),
        onDeleteKey: (int id) => confirmDeleteKey(context, id),
        onVerifyPinForUsbActions: () async => verifyPinForUsbActions(context),
      ),
      // FAB is already included in UsbKeyManagementView, no need to duplicate
    );
  }
}
