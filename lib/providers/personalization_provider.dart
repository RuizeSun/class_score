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

  // ---- 关闭行为 ----
  //
  // 关闭时收进托盘（默认开）：主窗口只是隐藏，程序继续跑，桌面课表胶囊与
  // 悬浮球保持显示；要真正退出得走托盘 / 悬浮球的「退出程序」。
  bool _closeToTray = true;
  bool get closeToTray => _closeToTray;

  // ---- 「查询」页左右分栏比例（左栏占比）----
  double _analysisSplitRatio = defaultAnalysisSplitRatio;
  double get analysisSplitRatio => _analysisSplitRatio;

  /// 分栏比例默认值与允许范围：避免任一栏被拖到不可用。
  static const double defaultAnalysisSplitRatio = 0.5;
  static const double minAnalysisSplitRatio = 0.2;
  static const double maxAnalysisSplitRatio = 0.8;

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
      // setSeedColor 以十六进制字符串存储（toRadixString(16)），
      // 因此这里必须按 radix: 16 解析，否则含字母的颜色值会解析失败。
      final colorValue = int.tryParse(colorStr, radix: 16);
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

    // 关闭进托盘：老用户没有这个 key，按默认值「开」处理。
    final closeToTray = await DatabaseHelper.instance.getSetting(
      'close_to_tray',
    );
    _closeToTray = closeToTray == null || closeToTray == 'true';

    // Load analysis split ratio
    final ratio = double.tryParse(
      (await DatabaseHelper.instance.getSetting('analysis_split_ratio')) ?? '',
    );
    if (ratio != null) {
      _analysisSplitRatio = ratio.clamp(
        minAnalysisSplitRatio,
        maxAnalysisSplitRatio,
      );
    }

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

  /// 设置「查询」页左右分栏比例并持久化。
  Future<void> setAnalysisSplitRatio(double value) async {
    final clamped = value.clamp(minAnalysisSplitRatio, maxAnalysisSplitRatio);
    if (clamped == _analysisSplitRatio) return;
    _analysisSplitRatio = clamped;
    await DatabaseHelper.instance.setSetting(
      'analysis_split_ratio',
      clamped.toString(),
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

  /// 关闭窗口时收进托盘（而不是真正退出）。
  Future<void> setCloseToTray(bool value) async {
    if (_closeToTray == value) return;
    _closeToTray = value;
    await DatabaseHelper.instance.setSetting(
      'close_to_tray',
      value.toString(),
    );
    notifyListeners();
  }
}
