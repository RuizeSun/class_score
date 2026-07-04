import 'package:flutter/material.dart';
import '../database/database_helper.dart';

/// Provider for personalization settings: theme color, window behavior when locked.
class PersonalizationProvider extends ChangeNotifier {
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  // ---- Theme ----
  Color _seedColor = Colors.indigo;
  Color get seedColor => _seedColor;

  // ---- Window behavior when locked ----
  bool _allowMinimizeWhenLocked = false;
  bool get allowMinimizeWhenLocked => _allowMinimizeWhenLocked;

  bool _allowCloseWhenLocked = false;
  bool get allowCloseWhenLocked => _allowCloseWhenLocked;

  /// Available Material 3 seed colors for user selection.
  static const List<Map<String, dynamic>> availableColors = [
    {'name': '靛蓝 (默认)', 'color': Colors.indigo},
    {'name': '蓝色', 'color': Colors.blue},
    {'name': '青色', 'color': Colors.teal},
    {'name': '绿色', 'color': Colors.green},
    {'name': '橙色', 'color': Colors.orange},
    {'name': '红色', 'color': Colors.red},
    {'name': '粉色', 'color': Colors.pink},
    {'name': '紫色', 'color': Colors.purple},
  ];

  Future<void> init() async {
    if (_isInitialized) return;

    // Load theme seed color
    final colorStr = await DatabaseHelper.instance.getSetting(
      'theme_seed_color',
    );
    if (colorStr != null && colorStr.isNotEmpty) {
      final colorValue = int.tryParse(colorStr);
      if (colorValue != null) {
        _seedColor = Color(colorValue);
      }
    }

    // Load window behavior settings
    final allowMinimize = await DatabaseHelper.instance.getSetting(
      'allow_minimize_locked',
    );
    _allowMinimizeWhenLocked = allowMinimize == 'true';

    final allowClose = await DatabaseHelper.instance.getSetting(
      'allow_close_locked',
    );
    _allowCloseWhenLocked = allowClose == 'true';

    _isInitialized = true;
    notifyListeners();
  }

  /// Set the theme seed color and persist.
  Future<void> setSeedColor(Color color) async {
    _seedColor = color;
    await DatabaseHelper.instance.setSetting(
      'theme_seed_color',
      color.toARGB32().toRadixString(16),
    );
    notifyListeners();
  }

  /// Toggle whether minimizing is allowed when the app is locked.
  Future<void> setAllowMinimizeWhenLocked(bool value) async {
    _allowMinimizeWhenLocked = value;
    await DatabaseHelper.instance.setSetting(
      'allow_minimize_locked',
      value.toString(),
    );
    notifyListeners();
  }

  /// Toggle whether closing is allowed when the app is locked.
  Future<void> setAllowCloseWhenLocked(bool value) async {
    _allowCloseWhenLocked = value;
    await DatabaseHelper.instance.setSetting(
      'allow_close_locked',
      value.toString(),
    );
    notifyListeners();
  }
}
