import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/desktop_schedule_state.dart';
import '../../models/weather_snapshot.dart';
import '../../services/desktop_bar_log.dart';
import '../../services/desktop_bar_window_channel.dart';
import '../../services/desktop_window_service.dart';
import '../../widgets/desktop_schedule/desktop_schedule_common.dart';
import '../../widgets/desktop_schedule/desktop_schedule_widget.dart';

/// 桌面条浮窗（独立 Flutter engine）的 Dart 入口。
///
/// 浮窗刻意「什么都不算」：不读数据库、不起计时器、不判断时间——所有状态都由
/// 主窗口算好后推过来。原因有两个：
/// 1. 主窗口已经在跑秒级状态机，两边各算一遍必然出现「条上写 53 秒、主窗口
///    写 52 秒」之类的偏差；
/// 2. 浮窗是独立 isolate，直接读 SQLite 会和主窗口争用同一个库文件。
///
/// 窗口样式（无边框、贴顶/贴底、透明度、鼠标穿透）通过 runner 的原生通道设置，
/// **不使用 window_manager**（原因见 [DesktopBarWindowChannel] 的说明）。
class DesktopBarWindow extends StatefulWidget {
  const DesktopBarWindow({super.key, this.launchArguments = const []});

  /// 引擎入口参数（仅用于写排查日志，运行逻辑不依赖它）。
  final List<String> launchArguments;

  @override
  State<DesktopBarWindow> createState() => _DesktopBarWindowState();
}

class _DesktopBarWindowState extends State<DesktopBarWindow> {
  /// 主窗口推来的完整状态；为 null 表示首帧数据还没到（此时不渲染内容，
  /// 避免闪一下「今日无课」）。
  DesktopScheduleState? _state;
  String? _weatherLabel;
  WeatherKind? _weatherKind;
  bool _showPreparationHint = false;
  double _scale = 1.0;

  /// 最近一次已应用到原生窗口的外观签名：只有变化才重新调用原生通道。
  String? _appliedAppearance;
  bool _appearanceApplied = false;
  int _payloadCount = 0;
  DesktopSchedulePhase? _lastLoggedPhase;

  /// 最近一条推送：窗口被隐藏后重新启用时，用它把外观重新应用一遍。
  Map<String, dynamic>? _lastPayload;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _log('Dart 入口已启动，参数=${widget.launchArguments}');

    try {
      final controller = await WindowController.fromCurrentEngine();
      await _log(
        '本窗口身份：id=${controller.windowId} arguments="${controller.arguments}"',
      );
      await controller.setWindowMethodHandler((call) async {
        switch (call.method) {
          case DesktopWindowService.pingMethod:
            return true;
          case DesktopWindowService.payloadMethod:
            await _applyPayload(asStringKeyedMap(call.arguments));
            return true;
          case DesktopWindowService.closeMethod:
            await DesktopBarWindowChannel.close();
            return true;
          case DesktopWindowService.showMethod:
            await _reapplyAppearance();
            return true;
          default:
            throw MissingPluginException('未实现的桌面条方法：${call.method}');
        }
      });
      await _log('已注册方法处理器，等待主窗口推送内容');
    } catch (error) {
      // 通道注册失败时浮窗会一直空着（主窗口的推送会被判为不可用），
      // 但主窗口本身不受影响；写文件日志便于定位（浮窗引擎的 debugPrint
      // 在 flutter run 下看不到）。
      await _log('注册方法处理器失败：$error');
    }
  }

  static Future<void> _log(String message) =>
      DesktopBarLog.write(DesktopWindowService.barTag, message);

  /// 应用主窗口推来的内容与外观参数。
  Future<void> _applyPayload(Map<String, dynamic> payload) async {
    final rawState = payload['state'];
    if (rawState is! Map) {
      await _log('收到的内容缺少 state 字段，已忽略');
      return;
    }
    final kindName = payload['weather_kind'] as String?;
    setState(() {
      _state = DesktopScheduleState.fromJson(asStringKeyedMap(rawState));
      _weatherLabel = payload['weather_label'] as String?;
      _weatherKind = kindName == null
          ? null
          : WeatherKind.values.firstWhere(
              (item) => item.name == kindName,
              orElse: () => WeatherKind.unknown,
            );
      _showPreparationHint =
          payload['show_preparation_hint'] as bool? ?? false;
      _scale = (payload['scale'] as num?)?.toDouble() ?? 1.0;
    });

    await _applyAppearance(payload);
    _lastPayload = payload;

    _payloadCount++;
    if (_payloadCount == 1) {
      await _log(
        '收到首条内容：阶段=${_state!.phase.name} 天气=${_weatherLabel ?? '无'} '
        '缩放=$_scale',
      );
    } else if (_lastLoggedPhase != _state!.phase) {
      // 只记阶段切换：内容每秒推送一次，全记会把日志刷爆，而排查
      // 「有没有按时上课/课间/倒计时」真正需要的是阶段时间线。
      await _log(
        '阶段切换：${_lastLoggedPhase?.name ?? '-'} → ${_state!.phase.name}'
        '（剩余 ${_state!.remaining.inSeconds}s，进度 '
        '${(_state!.progress * 100).toStringAsFixed(0)}%）',
      );
    }
    _lastLoggedPhase = _state!.phase;
  }

  /// 收到「显示」指令时重新应用外观（绕过签名去重）。
  Future<void> _reapplyAppearance() async {
    final payload = _lastPayload;
    if (payload == null) return;
    _appliedAppearance = null;
    await _applyAppearance(payload);
    await _log('收到显示指令，已重新应用窗口外观');
  }

  /// 把外观参数交给原生通道（无边框、居中悬浮、胶囊裁剪、透明度、穿透 + 显示窗口）。
  ///
  /// 外观随内容每秒推送一次，这里用签名去重，避免每秒都做一次窗口样式设置。
  Future<void> _applyAppearance(Map<String, dynamic> payload) async {
    final position = payload['position'] as String? ?? 'top';
    final layer = payload['layer'] as String? ?? 'desktop';
    final clickThrough = payload['click_through'] as bool? ?? true;
    final opacity = (payload['opacity'] as num?)?.toDouble() ?? 0.92;
    final barHeight = DesktopBarMetrics.height * _scale;
    // 胶囊宽度同样只是「请求值」：原生会把它收缩到工作区内，Flutter 侧的内容
    // 直接铺满窗口宽度即可，两边不会各算一套尺寸。
    final barWidth = DesktopBarMetrics.capsuleWidth * _scale;

    final signature =
        '$position|$layer|$clickThrough|$opacity|$barHeight|$barWidth';
    if (signature == _appliedAppearance) return;

    try {
      await DesktopBarWindowChannel.configure(
        position: position,
        layer: layer,
        clickThrough: clickThrough,
        opacity: opacity,
        barHeight: barHeight,
        barWidth: barWidth,
        screenMargin: DesktopBarMetrics.screenMargin,
      );
      _appliedAppearance = signature;
      if (!_appearanceApplied) {
        _appearanceApplied = true;
        await _log(
          '已应用窗口外观：位置=$position 层级=$layer 穿透=$clickThrough '
          '透明度=$opacity 胶囊=${barWidth}x$barHeight',
        );
      }
    } catch (error) {
      await _log('应用窗口外观失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: DesktopBarPalette.barBackground,
        body: state == null
            // 数据未到：留一块同色背景，等第一帧推送再画内容
            ? const SizedBox.expand()
            : DesktopScheduleWidget(
                state: state,
                weatherLabel: _weatherLabel,
                weatherKind: _weatherKind,
                showPreparationHint: _showPreparationHint,
                scale: _scale,
              ),
      ),
    );
  }
}
