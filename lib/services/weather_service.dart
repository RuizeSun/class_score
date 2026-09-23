import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/weather_snapshot.dart';

/// 天气服务：走 Open-Meteo（免费、无需注册与 API Key，可直连）。
///
/// 选它的原因：桌面条只需要「当前气温 + 天气现象」，而多数国内天气 API 需要
/// Key / 签名；Open-Meteo 直接按经纬度取数，返回值就是 WMO 天气码，解析成本最低。
///
/// 这里只负责「取数 + 解析」，不碰数据库、不缓存（缓存与刷新频率由
/// `DesktopScheduleProvider` 统一管理），这样网络层可以完全脱离数据库单测。
class WeatherService {
  WeatherService._();

  static final WeatherService instance = WeatherService._();

  /// 请求超时：天气是「锦上添花」，失败时宁可快速回退到缓存。
  static const Duration timeout = Duration(seconds: 8);

  /// 可注入的文本取用函数：默认真实网络请求，测试注入假响应。
  @visibleForTesting
  Future<String> Function(Uri uri)? textLoader;

  /// 取当前天气。[latitude] / [longitude] 为 WGS84 坐标。
  Future<WeatherSnapshot?> fetchCurrent({
    required double latitude,
    required double longitude,
    String locationName = '',
  }) async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': latitude.toString(),
      'longitude': longitude.toString(),
      'current': 'temperature_2m,weather_code',
      'timezone': 'auto',
    });

    final body = await _load(uri);
    if (body == null) return null;
    return parseCurrentResponse(body, locationName: locationName);
  }

  /// 城市名 → 候选坐标（设置页里让用户选具体城市）。
  Future<List<GeocodeResult>> searchCity(String query, {int count = 5}) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];

    final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': keyword,
      'count': count.toString(),
      'language': 'zh',
      'format': 'json',
    });

    final body = await _load(uri);
    if (body == null) return const [];
    return parseGeocodeResponse(body);
  }

  /// 解析当前天气响应；字段缺失或格式异常时返回 null。
  static WeatherSnapshot? parseCurrentResponse(
    String body, {
    String locationName = '',
    DateTime? now,
  }) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final current = json['current'] as Map<String, dynamic>?;
      if (current == null) return null;

      final temperature = current['temperature_2m'] as num?;
      final code = current['weather_code'] as num?;
      if (temperature == null || code == null) return null;

      return WeatherSnapshot(
        temperature: temperature.toDouble(),
        code: code.toInt(),
        updatedAt: now ?? DateTime.now(),
        locationName: locationName,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析地理编码响应。
  static List<GeocodeResult> parseGeocodeResponse(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final results = json['results'] as List<dynamic>? ?? const [];
      return results
          .whereType<Map<String, dynamic>>()
          .map(
            (item) => GeocodeResult(
              name: (item['name'] as String?) ?? '',
              latitude: (item['latitude'] as num?)?.toDouble() ?? 0,
              longitude: (item['longitude'] as num?)?.toDouble() ?? 0,
              admin: (item['admin1'] as String?) ?? '',
              country: (item['country'] as String?) ?? '',
            ),
          )
          .where((result) => result.name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 取回响应正文；任何异常（断网 / 超时 / 非 200 / 非法 URL）都返回 null，
  /// 由上层决定「显示缓存」还是「显示 --℃」。
  Future<String?> _load(Uri uri) async {
    final loader = textLoader;
    if (loader != null) {
      try {
        return await loader(uri);
      } catch (_) {
        return null;
      }
    }

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      return await response.transform(utf8.decoder).join().timeout(timeout);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
