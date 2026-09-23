/// 天气类型：由 WMO weather code 归一化而来。
///
/// 单独抽成枚举（而不是直接把 `weather_code` 丢给 UI）的原因：
/// 1. WMO 码有 20 多个取值，散落在 UI 里做 if-else 会很快失控；
/// 2. 图标由 UI 层映射，服务层保持纯数据，便于单测覆盖所有码段。
enum WeatherKind {
  clear,
  mainlyClear,
  partlyCloudy,
  overcast,
  fog,
  drizzle,
  freezingRain,
  rain,
  snow,
  rainShowers,
  snowShowers,
  thunderstorm,
  unknown,
}

/// 一次成功的天气取数结果。
class WeatherSnapshot {
  const WeatherSnapshot({
    required this.temperature,
    required this.code,
    required this.updatedAt,
    this.locationName = '',
  });

  /// 气温（摄氏度）。
  final double temperature;

  /// 原始 WMO weather code。
  final int code;

  /// 取数时间（用于判断缓存是否过期）。
  final DateTime updatedAt;

  /// 城市名（仅用于展示 / 排错，可为空）。
  final String locationName;

  /// 桌面条上的温度文案：「28℃」。
  String get temperatureLabel => '${temperature.round()}℃';

  WeatherKind get kind => WeatherSnapshot.kindOf(code);

  String get description => WeatherSnapshot.describe(kind);

  /// WMO weather code → [WeatherKind]（映射表见 Open-Meteo 文档）。
  static WeatherKind kindOf(int code) {
    switch (code) {
      case 0:
        return WeatherKind.clear;
      case 1:
        return WeatherKind.mainlyClear;
      case 2:
        return WeatherKind.partlyCloudy;
      case 3:
        return WeatherKind.overcast;
      case 45:
      case 48:
        return WeatherKind.fog;
      case 51:
      case 53:
      case 55:
        return WeatherKind.drizzle;
      case 56:
      case 57:
      case 66:
      case 67:
        return WeatherKind.freezingRain;
      case 61:
      case 63:
      case 65:
        return WeatherKind.rain;
      case 71:
      case 73:
      case 75:
      case 77:
        return WeatherKind.snow;
      case 80:
      case 81:
      case 82:
        return WeatherKind.rainShowers;
      case 85:
      case 86:
        return WeatherKind.snowShowers;
      case 95:
      case 96:
      case 99:
        return WeatherKind.thunderstorm;
      default:
        return WeatherKind.unknown;
    }
  }

  static String describe(WeatherKind kind) {
    switch (kind) {
      case WeatherKind.clear:
        return '晴';
      case WeatherKind.mainlyClear:
        return '晴间多云';
      case WeatherKind.partlyCloudy:
        return '多云';
      case WeatherKind.overcast:
        return '阴';
      case WeatherKind.fog:
        return '雾';
      case WeatherKind.drizzle:
        return '毛毛雨';
      case WeatherKind.freezingRain:
        return '冻雨';
      case WeatherKind.rain:
        return '雨';
      case WeatherKind.snow:
        return '雪';
      case WeatherKind.rainShowers:
        return '阵雨';
      case WeatherKind.snowShowers:
        return '阵雪';
      case WeatherKind.thunderstorm:
        return '雷雨';
      case WeatherKind.unknown:
        return '未知';
    }
  }

  Map<String, dynamic> toJson() => {
    'temperature': temperature,
    'code': code,
    'updated_at': updatedAt.toIso8601String(),
    'location_name': locationName,
  };

  factory WeatherSnapshot.fromJson(Map<String, dynamic> json) {
    return WeatherSnapshot(
      temperature: (json['temperature'] as num).toDouble(),
      code: (json['code'] as num).toInt(),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      locationName: (json['location_name'] as String?) ?? '',
    );
  }
}

/// 城市 → 经纬度的查询结果（Open-Meteo Geocoding API）。
class GeocodeResult {
  const GeocodeResult({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.admin = '',
    this.country = '',
  });

  final String name;
  final double latitude;
  final double longitude;
  final String admin;
  final String country;

  /// 「北京 · 北京市 · 中国」——用于设置页展示，避免重名城市选错。
  String get label => [
    name,
    if (admin.isNotEmpty && admin != name) admin,
    if (country.isNotEmpty) country,
  ].join(' · ');
}
