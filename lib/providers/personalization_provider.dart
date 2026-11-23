import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassQuality;
import 'package:win32/win32.dart';

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

  // ---- 低配机器自动降档 ----
  //
  // 教室一体机这类机器常见 i3 + 4GB 内存 + 核显：玻璃的片元着色器全部跑在
  // 核显上，4GB 的机器还要和系统、浏览器抢内存，standard 档很容易掉到 30fps
  // 以下。这里在启动时读一次物理内存，低于阈值就把默认档位直接给到「高性能」
  // ——用户仍可在设置里改回去（用户显式选择永远优先于这里的自动判断）。
  //
  // 只影响**没有显式设置过档位**的机器：一旦用户点过任何一档，DB 里就有值，
  // 这里的自动降档不再生效。

  /// 触发自动降档的物理内存上限（GB）。
  ///
  /// 4GB 及以下的机器按「低配」处理；8GB 起不做干预（教室一体机 8GB + 核显
  /// 在 standard 档下实测可以维持 60fps）。
  static const double lowSpecMemoryGb = 5.0;

  /// 当前机器是否被判为低配（决定默认档位与设置页的提示）。
  bool get isLowSpecDevice => _lowSpecDevice;
  bool _lowSpecDevice = false;

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
    _lowSpecDevice = _detectLowSpecDevice();
    final storedQuality = await DatabaseHelper.instance.getSetting(
      _keyGlassQuality,
    );

    // 从没选过档位、且本机是低配（如 i3 + 4GB 的教室一体机）时直接给
    // 「高性能」档：这类机器上玻璃着色器就是帧率的主要瓶颈，默认给均衡档
    // 相当于把每个新装机的老师都推进卡顿里。用户一旦在设置里点过任何一档，
    // 库里就有值，这里的自动降档不再生效。
    final useLowSpecDefault =
        (storedQuality == null || storedQuality.isEmpty) && _lowSpecDevice;

    _glassQuality = _supportedQuality(
      useLowSpecDefault
          ? GlassQuality.minimal
          : _parseGlassQuality(storedQuality),
    );

    _isInitialized = true;
    notifyListeners();
  }

  /// 读一次物理内存判断是否低配机器。
  ///
  /// 用 [GlobalMemoryStatusEx]（纯内存调用，几微秒），而不是 Process / WMI
  /// （要拉起子进程，启动路径上会卡住转圈）。任何异常都按「不是低配」处理：
  /// 降档是优化，不能因为它让启动失败。
  static bool _detectLowSpecDevice() {
    if (!Platform.isWindows) return false;
    try {
      final status = calloc<MEMORYSTATUSEX>();
      try {
        status.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
        if (GlobalMemoryStatusEx(status) == 0) return false;
        final totalGb = status.ref.ullTotalPhys / (1024 * 1024 * 1024);
        return totalGb.toDouble() <= lowSpecMemoryGb;
      } finally {
        calloc.free(status);
      }
    } catch (_) {
      return false;
    }
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
