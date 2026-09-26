import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../database/database_helper.dart';
import '../models/desktop_ball_style.dart';
import '../models/desktop_bar_style.dart';
import '../models/desktop_schedule_state.dart';
import '../models/weather_snapshot.dart';
import '../services/schedule_timeline_service.dart';
import '../services/weather_service.dart';
import '../widgets/desktop_schedule/desktop_schedule_common.dart';

/// 桌面课表（桌面条）的状态中枢。
///
/// 职责有三块，刻意集中在一个 Provider 里：
/// 1. **时间驱动**：每秒 tick 一次，用 `ScheduleTimelineService` 求解当前阶段；
/// 2. **天气**：按「刷新间隔」抽查，失败时回退到数据库里的最近一次结果；
/// 3. **配置**：所有 `desktop_*` 设置项都在这里读写，UI（设置页 / 预览）
///    与窗口层都只从这里取，避免设置值散落各处。
///
/// 为什么不复用 `AuthProvider` 的 10 秒轮询：那是给解锁状态用的，粒度到分钟；
/// 桌面条要显示「距上课还剩 53 秒」，必须有秒级推进。
class DesktopScheduleProvider extends ChangeNotifier {
  // ---- 持久化 key（app_settings 表）----
  static const String _keyEnabled = 'desktop_schedule_enabled';
  static const String _keyPosition = 'desktop_schedule_position';
  static const String _keyLayer = 'desktop_schedule_layer';
  static const String _keyClickThrough = 'desktop_schedule_click_through';
  static const String _keyOpacity = 'desktop_schedule_opacity';
  static const String _keyScale = 'desktop_schedule_scale';
  static const String _keyBallEnabled = 'desktop_ball_enabled';
  static const String _keyBallSizeRatio = 'desktop_ball_size_ratio';
  static const String _keyBallOffsetX = 'desktop_ball_offset_x';
  static const String _keyBallOffsetY = 'desktop_ball_offset_y';
  static const String _keyForegroundEnabled =
      'desktop_schedule_foreground_enabled';
  static const String _keyForegroundPosition =
      'desktop_schedule_foreground_position';
  static const String _keyForegroundLayer =
      'desktop_schedule_foreground_layer';
  static const String _keyForegroundClickThrough =
      'desktop_schedule_foreground_click_through';
  static const String _keyForegroundOpacity =
      'desktop_schedule_foreground_opacity';
  static const String _keyForegroundScale =
      'desktop_schedule_foreground_scale';
  static const String _keyPreClassAlert = 'desktop_schedule_pre_alert_minutes';
  static const String _keyNoticeDuration = 'desktop_schedule_notice_seconds';
  static const String _keyAlternate = 'desktop_schedule_alternate_seconds';
  static const String _keyWeatherEnabled = 'desktop_weather_enabled';
  static const String _keyWeatherCity = 'desktop_weather_city';
  static const String _keyWeatherLatitude = 'desktop_weather_latitude';
  static const String _keyWeatherLongitude = 'desktop_weather_longitude';
  static const String _keyWeatherRefresh = 'desktop_weather_refresh_minutes';
  static const String _keyWeatherCache = 'desktop_weather_cache';

  /// 秒级推进：倒计时需要每秒刷新，进度条也跟着走。
  static const Duration tickInterval = Duration(seconds: 1);

  /// 天气缓存超过这个时长就不再展示（避免显示昨天的温度）。
  static const Duration weatherStaleAfter = Duration(hours: 6);

  /// 配置项取值范围（设置页与解析兜底共用，避免出现非法值）。
  static const int minPreClassAlertMinutes = 1;
  static const int maxPreClassAlertMinutes = 10;
  static const int minNoticeSeconds = 1;
  static const int maxNoticeSeconds = 10;
  static const int minAlternateSeconds = 2;
  static const int maxAlternateSeconds = 15;
  static const int minWeatherRefreshMinutes = 5;
  static const int maxWeatherRefreshMinutes = 180;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  // ---- 配置 ----
  bool _enabled = false;
  bool get enabled => _enabled;

  DesktopBarPosition _position = DesktopBarPosition.top;
  DesktopBarPosition get position => _position;

  DesktopBarLayer _layer = DesktopBarLayer.desktop;
  DesktopBarLayer get layer => _layer;

  bool _clickThrough = true;
  bool get clickThrough => _clickThrough;

  double _opacity = 0.92;
  double get opacity => _opacity;

  double _scale = 1.0;
  double get scale => _scale;

  // ---- 桌面悬浮球 ----
  //
  // 球与「课表开关」相互独立：课表胶囊在屏上时球贴在它右侧（组合整体居中），
  // 否则停在屏幕右上角。位置只来自拖动（设置页不提供偏移滑块）。
  bool _ballEnabled = true;
  bool get ballEnabled => _ballEnabled;

  double _ballSizeRatio = defaultBallSizeRatio;
  double get ballSizeRatio => _ballSizeRatio;

  double _ballOffsetX = 0;
  double get ballOffsetX => _ballOffsetX;

  double _ballOffsetY = 0;
  double get ballOffsetY => _ballOffsetY;

  /// 无课表时球到工作区右上角的留白（与胶囊的顶部留白共用一套值）。
  double get ballMargin => DesktopBarMetrics.screenMargin;

  /// 当前缩放下的胶囊高度（逻辑像素）。无课表时原生用它推算球的直径，
  /// 保证「课表开着的球」和「课表关掉的球」大小一致。
  double get scaledCapsuleHeight => DesktopBarMetrics.height * scale;

  // ---- 前台态（有程序在前台时的第二套外观）----
  //
  // 默认关闭：老用户行为完全不变。开启后浮窗按原生探测到的前台状态在
  // [desktopAppearance] 与 [foregroundAppearance] 之间自动切换。
  bool _foregroundEnabled = false;
  bool get foregroundEnabled => _foregroundEnabled;

  DesktopBarPosition _foregroundPosition = DesktopBarPosition.top;
  DesktopBarPosition get foregroundPosition => _foregroundPosition;

  DesktopBarLayer _foregroundLayer = DesktopBarLayer.topMost;
  DesktopBarLayer get foregroundLayer => _foregroundLayer;

  bool _foregroundClickThrough = true;
  bool get foregroundClickThrough => _foregroundClickThrough;

  double _foregroundOpacity = 0.92;
  double get foregroundOpacity => _foregroundOpacity;

  double _foregroundScale = 1.0;
  double get foregroundScale => _foregroundScale;

  int _preClassAlertMinutes = 3;
  int get preClassAlertMinutes => _preClassAlertMinutes;

  int _noticeSeconds = 2;
  int get noticeSeconds => _noticeSeconds;

  int _alternateSeconds = 4;
  int get alternateSeconds => _alternateSeconds;

  bool _weatherEnabled = true;
  bool get weatherEnabled => _weatherEnabled;

  String _weatherCity = '';
  String get weatherCity => _weatherCity;

  double? _weatherLatitude;
  double? get weatherLatitude => _weatherLatitude;

  double? _weatherLongitude;
  double? get weatherLongitude => _weatherLongitude;

  int _weatherRefreshMinutes = 15;
  int get weatherRefreshMinutes => _weatherRefreshMinutes;

  bool get hasWeatherLocation =>
      _weatherLatitude != null && _weatherLongitude != null;

  // ---- 运行时状态 ----
  DesktopScheduleState _state = DesktopScheduleState(
    phase: DesktopSchedulePhase.restDay,
    slots: const [],
    now: DateTime.now(),
  );
  DesktopScheduleState get state => _state;

  WeatherSnapshot? _weather;
  WeatherSnapshot? get weather => _weather;

  List<Map<String, dynamic>> _courseSchedules = const [];
  List<Map<String, dynamic>> _scheduleAdjustments = const [];

  Timer? _ticker;
  Timer? _weatherTimer;
  bool _weatherLoading = false;

  /// 当前显示的天气文案（无数据时为 null，桌面条隐藏该块）。
  String? get weatherLabel {
    final weather = _weather;
    if (!_weatherEnabled || weather == null) return null;
    if (DateTime.now().difference(weather.updatedAt) > weatherStaleAfter) {
      return null;
    }
    return weather.temperatureLabel;
  }

  WeatherKind? get weatherKind => weatherLabel == null ? null : _weather?.kind;

  /// 图三（倒计时明细）↔ 图四（准备提醒）的交替相位。
  ///
  /// 用「距阶段开始经过的秒数」推导而不是内部计数器：状态自身就是时间的函数，
  /// 重启 / 时间被改动后相位依然连续，也方便单测直接断言。
  /// 图三（倒计时明细）↔ 图四（准备提醒）的交替相位。
  ///
  /// 用「距阶段开始经过的秒数」推导而不是内部计数器：状态自身就是时间的函数，
  /// 重启 / 时间被改动后相位依然连续，也方便单测直接断言。
  bool get showPreparationHint {
    if (_state.phase != DesktopSchedulePhase.preCountdown) return false;
    final start = _state.phaseStart;
    if (start == null) return false;
    final elapsed = _state.now.difference(start).inMilliseconds;
    final interval = _alternateSeconds * 1000;
    if (interval <= 0) return false;
    return (elapsed ~/ interval).isOdd;
  }

  /// 读取设置、恢复天气缓存并启动计时器；重复调用无副作用。
  Future<void> init() async {
    if (_isInitialized) return;
    final settings = DatabaseHelper.instance;

    _enabled = await _readBool(settings, _keyEnabled, fallback: false);
    _position = _parsePosition(await settings.getSetting(_keyPosition));
    _layer = _parseLayer(await settings.getSetting(_keyLayer));
    _clickThrough = await _readBool(settings, _keyClickThrough, fallback: true);
    _opacity = _parseDouble(await settings.getSetting(_keyOpacity), 0.92)
        .clamp(0.3, 1.0);
    _scale = _parseDouble(await settings.getSetting(_keyScale), 1.0).clamp(
      0.8,
      1.6,
    );
    _ballEnabled = await _readBool(settings, _keyBallEnabled, fallback: true);
    _ballSizeRatio = _parseDouble(
      await settings.getSetting(_keyBallSizeRatio),
      defaultBallSizeRatio,
    ).clamp(minBallSizeRatio, maxBallSizeRatio);
    _ballOffsetX = clampBallOffset(
      _parseDouble(await settings.getSetting(_keyBallOffsetX), 0),
    );
    _ballOffsetY = clampBallOffset(
      _parseDouble(await settings.getSetting(_keyBallOffsetY), 0),
    );
    _foregroundEnabled = await _readBool(
      settings,
      _keyForegroundEnabled,
      fallback: false,
    );
    _foregroundPosition = _parsePosition(
      await settings.getSetting(_keyForegroundPosition),
      fallback: DesktopBarPosition.top,
    );
    // 前台态默认置顶：程序盖在桌面上时，桌面级的胶囊会被完全挡住，
    // 功能看起来就像坏了。
    _foregroundLayer = _parseLayer(
      await settings.getSetting(_keyForegroundLayer),
      fallback: DesktopBarLayer.topMost,
    );
    _foregroundClickThrough = await _readBool(
      settings,
      _keyForegroundClickThrough,
      fallback: true,
    );
    _foregroundOpacity = _parseDouble(
      await settings.getSetting(_keyForegroundOpacity),
      0.92,
    ).clamp(0.3, 1.0);
    _foregroundScale = _parseDouble(
      await settings.getSetting(_keyForegroundScale),
      1.0,
    ).clamp(0.8, 1.6);
    _preClassAlertMinutes =
        _parseInt(
          await settings.getSetting(_keyPreClassAlert),
          _preClassAlertMinutes,
        ).clamp(minPreClassAlertMinutes, maxPreClassAlertMinutes);
    _noticeSeconds = _parseInt(
      await settings.getSetting(_keyNoticeDuration),
      _noticeSeconds,
    ).clamp(minNoticeSeconds, maxNoticeSeconds);
    _alternateSeconds = _parseInt(
      await settings.getSetting(_keyAlternate),
      _alternateSeconds,
    ).clamp(minAlternateSeconds, maxAlternateSeconds);
    _weatherEnabled = await _readBool(
      settings,
      _keyWeatherEnabled,
      fallback: true,
    );
    _weatherCity = (await settings.getSetting(_keyWeatherCity)) ?? '';
    _weatherLatitude = _parseNullableDouble(
      await settings.getSetting(_keyWeatherLatitude),
    );
    _weatherLongitude = _parseNullableDouble(
      await settings.getSetting(_keyWeatherLongitude),
    );
    _weatherRefreshMinutes = _parseInt(
      await settings.getSetting(_keyWeatherRefresh),
      _weatherRefreshMinutes,
    ).clamp(minWeatherRefreshMinutes, maxWeatherRefreshMinutes);
    _weather = _parseWeatherCache(await settings.getSetting(_keyWeatherCache));

    _isInitialized = true;
    _restartTicker();
    _recompute(force: true);
    // 天气不阻塞启动：首次取数最长会等一个网络超时，若同步等待，桌面条要好几秒
    // 才出现；先显示课表，天气到了再补上。
    unawaited(refreshWeather());
    _weatherTimer?.cancel();
    _weatherTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => refreshWeather(),
    );
  }

  /// 课表数据变化时由外部（AuthProvider 的监听）推入。
  void updateSchedules(
    List<Map<String, dynamic>> courseSchedules,
    List<Map<String, dynamic>> scheduleAdjustments, {
    DateTime? now,
  }) {
    _courseSchedules = courseSchedules;
    _scheduleAdjustments = scheduleAdjustments;
    _recompute(now: now, force: true);
  }

  /// 以 [now]（默认当前时间）重新求解状态。
  ///
  /// 倒计时文案与进度条都按秒变化，因此每次 tick 都要通知：桌面条本身很轻
  /// （一行内容 + 一条进度条），相比「每秒重建」的代价，状态不刷新才是 bug。
  void _recompute({DateTime? now, bool force = false}) {
    final moment = now ?? DateTime.now();
    final next = ScheduleTimelineService.resolve(
      courseSchedules: _courseSchedules,
      adjustments: _scheduleAdjustments,
      now: moment,
      preClassAlert: Duration(minutes: _preClassAlertMinutes),
      noticeDuration: Duration(seconds: _noticeSeconds),
    );
    _state = next;
    notifyListeners();
  }

  // ---- 配置写入：全部落库，设置页只调这些方法 ----

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    await _save(_keyEnabled, value.toString());
    notifyListeners();
    if (value) await refreshWeather(force: true);
  }

  Future<void> setPosition(DesktopBarPosition value) async {
    if (_position == value) return;
    _position = value;
    await _save(_keyPosition, value.name);
    notifyListeners();
  }

  Future<void> setLayer(DesktopBarLayer value) async {
    if (_layer == value) return;
    _layer = value;
    await _save(_keyLayer, value.name);
    notifyListeners();
  }

  Future<void> setClickThrough(bool value) async {
    if (_clickThrough == value) return;
    _clickThrough = value;
    await _save(_keyClickThrough, value.toString());
    notifyListeners();
  }

  Future<void> setOpacity(double value) async {
    final clamped = value.clamp(0.3, 1.0);
    if (_opacity == clamped) return;
    _opacity = clamped;
    await _save(_keyOpacity, clamped.toString());
    notifyListeners();
  }

  Future<void> setScale(double value) async {
    final clamped = value.clamp(0.8, 1.6);
    if (_scale == clamped) return;
    _scale = clamped;
    await _save(_keyScale, clamped.toString());
    notifyListeners();
  }

  // ---- 桌面悬浮球配置写入 ----

  Future<void> setBallEnabled(bool value) async {
    if (_ballEnabled == value) return;
    _ballEnabled = value;
    await _save(_keyBallEnabled, value.toString());
    notifyListeners();
  }

  /// 球径 = 胶囊高度 × 该比例，跟随「整体缩放」一起变。
  Future<void> setBallSizeRatio(double value) async {
    final clamped = value.clamp(minBallSizeRatio, maxBallSizeRatio);
    if (_ballSizeRatio == clamped) return;
    _ballSizeRatio = clamped;
    await _save(_keyBallSizeRatio, clamped.toString());
    notifyListeners();
  }

  /// 记录一次拖动结果：原生松手时回传的偏移（相对右上角默认位置）。
  Future<void> setBallOffset(double x, double y) async {
    final clampedX = clampBallOffset(x);
    final clampedY = clampBallOffset(y);
    if (clampedX == _ballOffsetX && clampedY == _ballOffsetY) return;
    _ballOffsetX = clampedX;
    _ballOffsetY = clampedY;
    await _save(_keyBallOffsetX, clampedX.toString());
    await _save(_keyBallOffsetY, clampedY.toString());
    notifyListeners();
  }

  /// 把球放回屏幕右上角的默认位置。
  Future<void> resetBallOffset() => setBallOffset(0, 0);

  // ---- 前台态配置写入 ----

  Future<void> setForegroundEnabled(bool value) async {
    if (_foregroundEnabled == value) return;
    _foregroundEnabled = value;
    await _save(_keyForegroundEnabled, value.toString());
    notifyListeners();
  }

  Future<void> setForegroundPosition(DesktopBarPosition value) async {
    if (_foregroundPosition == value) return;
    _foregroundPosition = value;
    await _save(_keyForegroundPosition, value.name);
    notifyListeners();
  }

  Future<void> setForegroundLayer(DesktopBarLayer value) async {
    if (_foregroundLayer == value) return;
    _foregroundLayer = value;
    await _save(_keyForegroundLayer, value.name);
    notifyListeners();
  }

  Future<void> setForegroundClickThrough(bool value) async {
    if (_foregroundClickThrough == value) return;
    _foregroundClickThrough = value;
    await _save(_keyForegroundClickThrough, value.toString());
    notifyListeners();
  }

  Future<void> setForegroundOpacity(double value) async {
    final clamped = value.clamp(0.3, 1.0);
    if (_foregroundOpacity == clamped) return;
    _foregroundOpacity = clamped;
    await _save(_keyForegroundOpacity, clamped.toString());
    notifyListeners();
  }

  Future<void> setForegroundScale(double value) async {
    final clamped = value.clamp(0.8, 1.6);
    if (_foregroundScale == clamped) return;
    _foregroundScale = clamped;
    await _save(_keyForegroundScale, clamped.toString());
    notifyListeners();
  }

  /// 提前提醒时间（分钟）：越早进入「即将上课 → 倒计时」流程。
  Future<void> setPreClassAlertMinutes(int value) async {
    final clamped = value.clamp(minPreClassAlertMinutes, maxPreClassAlertMinutes);
    if (_preClassAlertMinutes == clamped) return;
    _preClassAlertMinutes = clamped;
    await _save(_keyPreClassAlert, clamped.toString());
    _recompute(force: true);
  }

  /// 图二 / 图五横幅的显示时长（秒）。
  Future<void> setNoticeSeconds(int value) async {
    final clamped = value.clamp(minNoticeSeconds, maxNoticeSeconds);
    if (_noticeSeconds == clamped) return;
    _noticeSeconds = clamped;
    await _save(_keyNoticeDuration, clamped.toString());
    _recompute(force: true);
  }

  /// 图三 ↔ 图四的交替间隔（秒）。
  Future<void> setAlternateSeconds(int value) async {
    final clamped = value.clamp(minAlternateSeconds, maxAlternateSeconds);
    if (_alternateSeconds == clamped) return;
    _alternateSeconds = clamped;
    await _save(_keyAlternate, clamped.toString());
    notifyListeners();
  }

  Future<void> setWeatherEnabled(bool value) async {
    if (_weatherEnabled == value) return;
    _weatherEnabled = value;
    await _save(_keyWeatherEnabled, value.toString());
    notifyListeners();
    if (value) await refreshWeather(force: true);
  }

  /// 设置天气位置（城市名 + 经纬度），设置页选好城市后调用。
  Future<void> setWeatherLocation({
    required String city,
    required double latitude,
    required double longitude,
  }) async {
    _weatherCity = city;
    _weatherLatitude = latitude;
    _weatherLongitude = longitude;
    await _save(_keyWeatherCity, city);
    await _save(_keyWeatherLatitude, latitude.toString());
    await _save(_keyWeatherLongitude, longitude.toString());
    notifyListeners();
    await refreshWeather(force: true);
  }

  Future<void> setWeatherRefreshMinutes(int value) async {
    final clamped = value.clamp(
      minWeatherRefreshMinutes,
      maxWeatherRefreshMinutes,
    );
    if (_weatherRefreshMinutes == clamped) return;
    _weatherRefreshMinutes = clamped;
    await _save(_keyWeatherRefresh, clamped.toString());
    notifyListeners();
  }
  // ---- 天气 ----

  /// 取一次天气；未到刷新间隔（且非强制）时直接跳过。
  ///
  /// 失败时保留上一次结果（[weatherLabel] 会按 [weatherStaleAfter] 判定是否
  /// 还能用），因此断网不会让桌面条出现空档或报错。
  Future<void> refreshWeather({bool force = false}) async {
    if (!_weatherEnabled || !hasWeatherLocation || _weatherLoading) return;

    final cached = _weather;
    if (!force && cached != null) {
      final age = DateTime.now().difference(cached.updatedAt);
      if (age < Duration(minutes: _weatherRefreshMinutes)) return;
    }

    _weatherLoading = true;
    try {
      final snapshot = await WeatherService.instance.fetchCurrent(
        latitude: _weatherLatitude!,
        longitude: _weatherLongitude!,
        locationName: _weatherCity,
      );
      if (snapshot != null) {
        _weather = snapshot;
        await _save(_keyWeatherCache, jsonEncode(snapshot.toJson()));
      }
    } finally {
      _weatherLoading = false;
      notifyListeners();
    }
  }

  /// 推送给桌面浮窗的数据快照。
  ///
  /// 浮窗运行在独立的 Flutter engine（独立 isolate）里，不让它直接读数据库；
  /// 主窗口把「已算好的状态 + 外观参数」整体推过去，两边渲染同一份数据。
  /// 外观参数也放在这里，浮窗发现变化时再调原生通道设置窗口样式。
  Map<String, dynamic> toBarPayload() {
    final label = weatherLabel;
    final reserve = desktopBallReserve(
      ballEnabled: _ballEnabled,
      sizeRatio: _ballSizeRatio,
    );
    return {
      'state': _state.toJson(),
      'weather_label': label,
      'weather_kind': label == null ? null : _weather!.kind.name,
      'weather_description': label == null ? null : _weather!.description,
      'show_preparation_hint': showPreparationHint,
      // 桌面态（无程序遮挡）：键名沿用旧字段，浮窗解析向后兼容。
      'scale': _scale,
      'opacity': _opacity,
      'position': _position.name,
      'layer': _layer.name,
      'click_through': _clickThrough,
      // 前台态（有程序在前台）：开关 + 第二套外观，由浮窗按原生探测到的
      // 前台状态与开关一起选出实际生效值（pickDesktopBarAppearance）。
      'foreground_enabled': _foregroundEnabled,
      'foreground_scale': _foregroundScale,
      'foreground_opacity': _foregroundOpacity,
      'foreground_position': _foregroundPosition.name,
      'foreground_layer': _foregroundLayer.name,
      'foreground_click_through': _foregroundClickThrough,
      // 悬浮球占位（只有球开着才让位，关掉即回到老布局）：原生按
      // gap + 胶囊高 × ratio 算出让位宽度并把胶囊左移半个让位，使
      // 「胶囊 + 悬浮球」整体居中。这两个值与推给球的是同一套，两边算出的
      // 整数必然一致。
      'ball_gap': reserve.gap,
      'ball_ratio': reserve.ratio,
    };
  }

  // ---- 内部工具 ----

  Future<void> _save(String key, String value) =>
      DatabaseHelper.instance.setSetting(key, value);

  static Future<bool> _readBool(
    DatabaseHelper settings,
    String key, {
    required bool fallback,
  }) async {
    final value = await settings.getSetting(key);
    if (value == null) return fallback;
    return value == 'true';
  }

  static int _parseInt(String? value, int fallback) =>
      int.tryParse(value ?? '') ?? fallback;

  static double _parseDouble(String? value, double fallback) =>
      double.tryParse(value ?? '') ?? fallback;

  static double? _parseNullableDouble(String? value) =>
      double.tryParse(value ?? '');

  static DesktopBarPosition _parsePosition(
    String? value, {
    DesktopBarPosition fallback = DesktopBarPosition.top,
  }) =>
      DesktopBarPosition.values.firstWhere(
        (item) => item.name == value,
        orElse: () => fallback,
      );

  static DesktopBarLayer _parseLayer(
    String? value, {
    DesktopBarLayer fallback = DesktopBarLayer.desktop,
  }) =>
      DesktopBarLayer.values.firstWhere(
        (item) => item.name == value,
        orElse: () => fallback,
      );

  static WeatherSnapshot? _parseWeatherCache(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return WeatherSnapshot.fromJson(
        jsonDecode(value) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  void _restartTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(
      tickInterval,
      (_) => _recompute(),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _weatherTimer?.cancel();
    super.dispose();
  }
}
