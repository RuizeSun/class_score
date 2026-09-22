import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 圆形数字键的直径（宽高相同，保证按键是正圆）。
const double _keyDiameter = 60;

/// 同一行相邻按键之间的水平间距（每个键左右各留一半，行的首尾同样留一半）。
const double _keyGap = 12;

/// 键位布局：3 列 × 4 行（前三行为 1~9，第四行为「清空 / 0 / ⌫」）。
const int _keyColumns = 3;
const int _keyRows = 4;

/// 3×4 的圆形数字键盘。
///
/// [PinPad] 与 [LongPinPad] 只在「顶部提示」和「确认按钮」上不同，键盘本身
/// 完全一致；抽出来共用一份，避免两份重复的 _keyLabel / _buildKey 各自漂移
/// （改键位或改外观时只改到一处）。
class _NumpadKeys extends StatelessWidget {
  const _NumpadKeys({
    required this.currentPin,
    required this.onPinChanged,
    required this.maxLength,
    this.onConfirm,
  });

  /// 已输入的 PIN。
  final String currentPin;

  /// 输入变化回调：数字追加、退格、清空都通过它回传。
  final ValueChanged<String> onPinChanged;

  /// 允许输入的最大位数；达到该长度时自动调用 [onConfirm]。
  final int maxLength;

  /// 输入满 [maxLength] 位后的自动确认回调，为 null 时只做长度限制。
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int row = 0; row < _keyRows; row++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int col = 0; col < _keyColumns; col++)
                  _buildKey(_keyLabel(row, col)),
              ],
            ),
          ),
      ],
    );
  }

  /// 每个键位的标签：前三行是 1~9，最后一行是「清空 / 0 / ⌫」。
  String _keyLabel(int row, int col) {
    if (row == _keyRows - 1) {
      if (col == 0) return '清空';
      if (col == 1) return '0';
      return '⌫';
    }
    return '${row * _keyColumns + col + 1}';
  }

  void _handleKey(String label) {
    HapticFeedback.lightImpact();
    if (label == '⌫') {
      if (currentPin.isNotEmpty) {
        onPinChanged(currentPin.substring(0, currentPin.length - 1));
      }
    } else if (label == '清空') {
      onPinChanged('');
    } else {
      if (currentPin.length < maxLength) {
        final newPin = currentPin + label;
        onPinChanged(newPin);
        // 输入满位数后自动确认
        if (newPin.length == maxLength && onConfirm != null) {
          onConfirm!();
        }
      }
    }
  }

  Widget _buildKey(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _keyGap / 2),
      child: SizedBox(
        width: _keyDiameter,
        height: _keyDiameter,
        child: TextButton(
          // 圆形按键若不裁剪，按压水波会溢出圆外。
          clipBehavior: Clip.antiAlias,
          style: TextButton.styleFrom(
            backgroundColor: Colors.grey.shade100,
            foregroundColor: Colors.black87,
            padding: EdgeInsets.zero,
            shape: CircleBorder(side: BorderSide(color: Colors.grey.shade300)),
          ),
          onPressed: () => _handleKey(label),
          // 「清空」是两个字，用数字键的字号放进圆内会溢出，单独缩小。
          child: Text(
            label,
            style: TextStyle(
              fontSize: label.length > 1 ? 15 : 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

class LongPinPad extends StatelessWidget {
  final int maxLength;
  final String currentPin;
  final ValueChanged<String> onPinChanged;
  final VoidCallback? onConfirm;

  const LongPinPad({
    super.key,
    this.maxLength = 100,
    required this.currentPin,
    required this.onPinChanged,
    this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Length indicator
        Text(
          '${currentPin.length} / $maxLength',
          style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 16),
        // Number pad
        _NumpadKeys(
          currentPin: currentPin,
          onPinChanged: onPinChanged,
          maxLength: maxLength,
          onConfirm: onConfirm,
        ),
        const SizedBox(height: 8),
        // Confirm button
        SizedBox(
          width: 200,
          height: 44,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: currentPin.length >= 6 && onConfirm != null
                ? onConfirm
                : null,
            child: const Text(
              '确认',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }
}

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
        _NumpadKeys(
          currentPin: currentPin,
          onPinChanged: onPinChanged,
          maxLength: pinLength,
          onConfirm: onConfirm,
        ),
      ],
    );
  }
}
