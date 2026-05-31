import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PinPad extends StatelessWidget {
  final int pinLength;
  final String currentPin;
  final ValueChanged<String> onPinChanged;
  final VoidCallback? onConfirm;

  const PinPad({
    super.key,
    this.pinLength = 6,
    required this.currentPin,
    required this.onPinChanged,
    this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Pin indicator dots
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(pinLength, (i) {
            final filled = i < currentPin.length;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 6),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? Colors.indigo : Colors.grey.shade300,
                border: Border.all(color: Colors.grey.shade400),
              ),
            );
          }),
        ),
        const SizedBox(height: 24),
        // Number pad
        for (int row = 0; row < 4; row++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (col) {
                final num = _keyLabel(row, col);
                if (num == null) return const SizedBox(width: 72);
                return _buildKey(num);
              }),
            ),
          ),
      ],
    );
  }

  String? _keyLabel(int row, int col) {
    if (row == 3) {
      if (col == 0) return '清空';
      if (col == 1) return '0';
      if (col == 2) return '⌫';
    }
    return '${row * 3 + col + 1}';
  }

  Widget _buildKey(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        width: 64,
        height: 52,
        child: TextButton(
          style: TextButton.styleFrom(
            backgroundColor: Colors.grey.shade100,
            foregroundColor: Colors.black87,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: Colors.grey.shade300),
            ),
          ),
          onPressed: () {
            HapticFeedback.lightImpact();
            if (label == '⌫') {
              if (currentPin.isNotEmpty) {
                onPinChanged(currentPin.substring(0, currentPin.length - 1));
              }
            } else if (label == '清空') {
              onPinChanged('');
            } else {
              if (currentPin.length < pinLength) {
                final newPin = currentPin + label;
                onPinChanged(newPin);
                if (newPin.length == pinLength && onConfirm != null) {
                  onConfirm!();
                }
              }
            }
          },
          child: Text(
            label,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}
