import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassQuality;

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

  // ---- 玻璃质感档位 ----
  static const String _keyGlassQuality = 'glass_quality';
  static const GlassQuality defaultGlassQuality = GlassQuality.standard;

  /// Windows 上禁用 [GlassQuality.premium]。
  ///
  /// premium 走的是 Impeller 的多趟 shader + 同步纹理回读；在 Windows 上首次
  /// 渲染会卡住 UI isolate 十几秒（启动转圈因此完全不动），连桌面课表浮窗
  /// 引擎的创建都被拖慢。standard 用轻量 shader，本机实测首帧约 0.6s。
  static bool get _premiumSupported => !Platform.isWindows;

  /// 设置页展示顺序：高质感 → 均衡 → 高性能（Windows 上不展示高质感）。
  static List<GlassQuality> get availableGlassQualities => [
    if (_premiumSupported) GlassQuality.premium,
    GlassQuality.standard,
    GlassQuality.minimal,
  ];

  static const Map<GlassQuality, String> glassQualityLabels = {
    GlassQuality.premium: '高质感',
    GlassQuality.standard: '均衡（默认）',
    GlassQuality.minimal: '高性能',
  };

  static const Map<GlassQuality, String> glassQualityDescriptions = {
    GlassQuality.premium: '完整玻璃效果，观感最好；需要较强的显卡',
    GlassQuality.standard: '轻量着色器，保留玻璃观感且负担更小',
    GlassQuality.minimal: '无自定义 shader，只用背景模糊，最流畅',
  };

  /// 把不支持的档位降级：Windows 上 premium → standard。
  static GlassQuality _supportedQuality(GlassQuality quality) =>
      !_premiumSupported && quality == GlassQuality.premium
      ? GlassQuality.standard
      : quality;

  GlassQuality _glassQuality = defaultGlassQuality;
  GlassQuality get glassQuality => _glassQuality;

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

    // 玻璃档位：老用户没有这个 key 按默认档；历史数据里存过 Windows 上
    // 不支持的 premium 时一并降级，否则启动仍会被多趟 shader 卡住。
    _glassQuality = _supportedQuality(
      _parseGlassQuality(
        await DatabaseHelper.instance.getSetting(_keyGlassQuality),
      ),
    );

    _isInitialized = true;
    notifyListeners();
  }

  static GlassQuality _parseGlassQuality(String? stored) {
    for (final quality in GlassQuality.values) {
      if (quality.name == stored) return quality;
    }
    return defaultGlassQuality;
  }

  /// 切换玻璃档位后立即可见（相关控件都 watch 本 Provider）。
  Future<void> setGlassQuality(GlassQuality quality) async {
    final supported = _supportedQuality(quality);
    if (_glassQuality == supported) return;
    _glassQuality = supported;
    await DatabaseHelper.instance.setSetting(_keyGlassQuality, supported.name);
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
    await DatabaseHelper.instance.setSetting('close_to_tray', value.toString());
    notifyListeners();
  }
}
