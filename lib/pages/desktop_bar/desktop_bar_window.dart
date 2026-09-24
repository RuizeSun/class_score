import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/desktop_bar_style.dart';
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

  /// 最近一次探测到的「有程序在前台」状态（查询失败时沿用上次值）。
  bool _foregroundActive = false;
  bool? _lastLoggedForeground;

  /// 上次选取外观时用到的前台标记：与当前值对比得出「前台态是否翻转」。
  bool? _selectionForeground;

  /// 正在播放切换动画（淡出 → 换外观 → 淡入）。
  ///
  /// 动画约 0.36s、内容每秒推送一次，正常不会重叠；万一重叠，后来的推送
  /// 直接生效（跳过动画），不让两次淡化互相打架。
  bool _transitioning = false;

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
  ///
  /// 每次推送（每秒一次）顺带向原生查询「是否有程序在前台」，与 payload 里的
  /// 双外观配置一起选出**实际生效**的那套外观：窗口样式与内容缩放都跟着它走。
  ///
  /// 「桌面态 ↔ 前台态」切换播放交叉淡化：旧外观**原地**淡出 → 窗口切到新
  /// 几何 / 层级、内容换成新缩放（全透明瞬间完成）→ 新外观淡入。淡出期间
  /// 不更新任何状态，内容与窗口保持同为旧外观，不会出现尺寸错位。
  Future<void> _applyPayload(Map<String, dynamic> payload) async {
    final rawState = payload['state'];
    if (rawState is! Map) {
      await _log('收到的内容缺少 state 字段，已忽略');
      return;
    }
    final resolved = await _resolveAppearance(payload);
    final appearance = resolved.appearance;

    final crossFade =
        !_transitioning &&
        shouldAnimateDesktopBarSwitch(
          alreadyApplied: _appearanceApplied,
          foregroundFlipped: resolved.flipped,
          appearanceChanged: _signatureOf(appearance) != _appliedAppearance,
        );
    if (crossFade) {
      _transitioning = true;
      try {
        await DesktopBarWindowChannel.fadeOut();
      } catch (error) {
        await _log('切换淡出失败（按直接切换处理）：$error');
      }
    }

    try {
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
        _scale = appearance.scale;
      });

      await _applyAppearance(
        appearance,
        // 交叉淡化的后半段淡入；首次出现（窗口刚创建）也淡入。
        fadeIn: crossFade || !_appearanceApplied,
      );
    } finally {
      if (crossFade) _transitioning = false;
    }
    _lastPayload = payload;

    _payloadCount++;
    if (_payloadCount == 1) {
      await _log(
        '收到首条内容：阶段=${_state!.phase.name} 天气=${_weatherLabel ?? '无'} '
        '缩放=$_scale 前台态=$_foregroundActive',
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

  /// 解析 payload 里的两套外观，并按当前前台状态选出实际生效的一套。
  ///
  /// 同时返回 [flipped]：双外观开关打开、且前台标记相对上一次选取发生了翻转
  /// （调用方据此决定是否播放切换动画）。查询失败（例如通道尚未就绪）时沿用
  /// [_foregroundActive] 的上次值，不打断内容推送。
  Future<({DesktopBarAppearance appearance, bool flipped})>
  _resolveAppearance(Map<String, dynamic> payload) async {
    final desktop = DesktopBarAppearance(
      position: _parsePosition(payload['position']),
      layer: _parseLayer(payload['layer']),
      clickThrough: payload['click_through'] as bool? ?? true,
      opacity: (payload['opacity'] as num?)?.toDouble() ?? 0.92,
      scale: (payload['scale'] as num?)?.toDouble() ?? 1.0,
    );
    final foreground = DesktopBarAppearance(
      position: _parsePosition(payload['foreground_position']),
      // 前台态默认置顶：程序盖在桌面上时，桌面级胶囊会被完全挡住。
      layer: _parseLayer(
        payload['foreground_layer'],
        fallback: DesktopBarLayer.topMost,
      ),
      clickThrough: payload['foreground_click_through'] as bool? ?? true,
      opacity: (payload['foreground_opacity'] as num?)?.toDouble() ?? 0.92,
      scale: (payload['foreground_scale'] as num?)?.toDouble() ?? 1.0,
    );
    final foregroundEnabled =
        payload['foreground_enabled'] as bool? ?? false;

    final previousSelection = _selectionForeground;
    try {
      _foregroundActive = await DesktopBarWindowChannel.getForeground();
    } catch (error) {
      await _log('查询前台状态失败（沿用上次值=$_foregroundActive）：$error');
    }
    if (_lastLoggedForeground != _foregroundActive) {
      await _log(
        _foregroundActive
            ? '检测到程序在前台，切换到前台外观'
            : '回到桌面态，切换到桌面外观',
      );
      _lastLoggedForeground = _foregroundActive;
    }
    final flipped =
        foregroundEnabled &&
        previousSelection != null &&
        previousSelection != _foregroundActive;
    _selectionForeground = _foregroundActive;

    return (
      appearance: pickDesktopBarAppearance(
        foregroundEnabled: foregroundEnabled,
        foregroundActive: _foregroundActive,
        desktop: desktop,
        foreground: foreground,
      ),
      flipped: flipped,
    );
  }

  static DesktopBarPosition _parsePosition(
    Object? value, {
    DesktopBarPosition fallback = DesktopBarPosition.top,
  }) =>
      DesktopBarPosition.values.firstWhere(
        (item) => item.name == value,
        orElse: () => fallback,
      );

  static DesktopBarLayer _parseLayer(
    Object? value, {
    DesktopBarLayer fallback = DesktopBarLayer.desktop,
  }) =>
      DesktopBarLayer.values.firstWhere(
        (item) => item.name == value,
        orElse: () => fallback,
      );

  /// 收到「显示」指令时重新应用外观并柔和淡入（绕过签名去重）。
  Future<void> _reapplyAppearance() async {
    final payload = _lastPayload;
    if (payload == null) return;
    _appliedAppearance = null;
    final resolved = await _resolveAppearance(payload);
    await _applyAppearance(resolved.appearance, fadeIn: true);
    await _log('收到显示指令，已重新应用窗口外观');
  }

  /// 生效外观的去重签名：只有变化才重新调用原生通道。
  static String _signatureOf(DesktopBarAppearance appearance) =>
      '${appearance.position.name}|${appearance.layer.name}|'
      '${appearance.clickThrough}|${appearance.opacity}|'
      '${DesktopBarMetrics.height * appearance.scale}|'
      '${DesktopBarMetrics.capsuleWidth * appearance.scale}';

  /// 把生效外观交给原生通道（无边框、居中悬浮、胶囊裁剪、透明度、穿透 + 显示窗口）。
  ///
  /// 外观随内容每秒推送一次，这里用签名去重，避免每秒都做一次窗口样式设置。
  /// [fadeIn] 为 true 时（切换淡入 / 首次出现 / 重新显示）先把窗口压到全透明
  /// 应用几何，再原生淡入到目标不透明度。
  Future<void> _applyAppearance(
    DesktopBarAppearance appearance, {
    required bool fadeIn,
  }) async {
    final signature = _signatureOf(appearance);
    if (signature == _appliedAppearance && !fadeIn) return;

    final barHeight = DesktopBarMetrics.height * appearance.scale;
    // 胶囊宽度同样只是「请求值」：原生会把它收缩到工作区内，Flutter 侧的内容
    // 直接铺满窗口宽度即可，两边不会各算一套尺寸。
    final barWidth = DesktopBarMetrics.capsuleWidth * appearance.scale;

    Future<void> applyNative(double opacity) =>
        DesktopBarWindowChannel.configure(
          position: appearance.position.name,
          layer: appearance.layer.name,
          clickThrough: appearance.clickThrough,
          opacity: opacity,
          barHeight: barHeight,
          barWidth: barWidth,
          screenMargin: DesktopBarMetrics.screenMargin,
        );

    try {
      // 淡入期间先全透明落地新几何；去重签名仍记目标值，
      // 后续相同外观不会因这个 0 重复配置。
      await applyNative(fadeIn ? 0.0 : appearance.opacity);
      _appliedAppearance = signature;
      if (fadeIn) {
        try {
          await DesktopBarWindowChannel.fadeIn(opacity: appearance.opacity);
        } catch (error) {
          await _log('切换淡入失败（直接显示目标不透明度）：$error');
          // 兜底：淡入挂掉不能把窗口留在全透明上。
          try {
            await applyNative(appearance.opacity);
          } catch (fallbackError) {
            await _log('恢复不透明度失败：$fallbackError');
          }
        }
      }
      if (!_appearanceApplied) {
        _appearanceApplied = true;
        await _log(
          '已应用窗口外观：位置=${appearance.position.name} '
          '层级=${appearance.layer.name} 穿透=${appearance.clickThrough} '
          '透明度=${appearance.opacity} 胶囊=${barWidth}x$barHeight',
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
