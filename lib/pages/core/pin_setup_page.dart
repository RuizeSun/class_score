import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/pin_pad.dart';

class PinSetupPage extends StatefulWidget {
  const PinSetupPage({super.key});

  @override
  State<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends State<PinSetupPage> {
  String _pin = '';
  String _confirmPin = '';
  bool _isConfirming = false;
  String? _error;

  void _onPinChanged(String value) {
    setState(() {
      _pin = value;
      _error = null;
    });
    if (value.length == 6 && !_isConfirming) {
      setState(() => _isConfirming = true);
    }
  }

  void _onConfirmChanged(String value) {
    setState(() {
      _confirmPin = value;
      _error = null;
    });
    if (value.length == 6) {
      if (value == _pin) {
        context.read<AuthProvider>().setPin(value);
      } else {
        setState(() {
          _error = '两次输入的 PIN 码不一致，请重新设置';
          _isConfirming = false;
          _pin = '';
          _confirmPin = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置安全 PIN 码')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 64, color: Colors.indigo.shade300),
              const SizedBox(height: 16),
              Text(
                _isConfirming ? '请再次输入 6 位 PIN 码' : '首次使用，请设置 6 位 PIN 码',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              PinPad(
                currentPin: _isConfirming ? _confirmPin : _pin,
                onPinChanged: _isConfirming ? _onConfirmChanged : _onPinChanged,
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
