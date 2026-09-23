import 'package:class_score/models/weather_snapshot.dart';
import 'package:class_score/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('当前天气解析', () {
    test('解析温度与天气码，温度文案取整到摄氏度', () {
      final snapshot = WeatherService.parseCurrentResponse(
        '{"current":{"time":"2026-09-23T10:00","temperature_2m":28.4,'
        '"weather_code":3}}',
        locationName: '北京',
        now: DateTime(2026, 9, 23, 10),
      );

      expect(snapshot, isNotNull);
      expect(snapshot!.temperature, 28.4);
      expect(snapshot.temperatureLabel, '28℃');
      expect(snapshot.code, 3);
      expect(snapshot.kind, WeatherKind.overcast);
      expect(snapshot.description, '阴');
      expect(snapshot.locationName, '北京');
    });

    test('字段缺失或响应非法时返回 null（不抛异常）', () {
      expect(
        WeatherService.parseCurrentResponse('{"current":{}}'),
        isNull,
      );
      expect(WeatherService.parseCurrentResponse('{}'), isNull);
      expect(WeatherService.parseCurrentResponse('not a json'), isNull);
      expect(
        WeatherService.parseCurrentResponse(
          '{"current":{"temperature_2m":20}}',
        ),
        isNull,
      );
    });

    test('WMO 天气码映射到归一化的天气类型与中文描述', () {
      const expected = {
        0: WeatherKind.clear,
        1: WeatherKind.mainlyClear,
        2: WeatherKind.partlyCloudy,
        3: WeatherKind.overcast,
        45: WeatherKind.fog,
        48: WeatherKind.fog,
        53: WeatherKind.drizzle,
        57: WeatherKind.freezingRain,
        65: WeatherKind.rain,
        67: WeatherKind.freezingRain,
        75: WeatherKind.snow,
        77: WeatherKind.snow,
        81: WeatherKind.rainShowers,
        86: WeatherKind.snowShowers,
        95: WeatherKind.thunderstorm,
        99: WeatherKind.thunderstorm,
        1234: WeatherKind.unknown,
      };

      expected.forEach((code, kind) {
        expect(WeatherSnapshot.kindOf(code), kind, reason: 'WMO code $code');
      });
      expect(WeatherSnapshot.describe(WeatherKind.clear), '晴');
      expect(WeatherSnapshot.describe(WeatherKind.rainShowers), '阵雨');
      expect(WeatherSnapshot.describe(WeatherKind.unknown), '未知');
    });

    test('快照可序列化 / 反序列化后保持一致（用于天气缓存）', () {
      final snapshot = WeatherSnapshot(
        temperature: 21.6,
        code: 61,
        updatedAt: DateTime(2026, 9, 23, 8, 30),
        locationName: '上海',
      );

      final restored = WeatherSnapshot.fromJson(snapshot.toJson());

      expect(restored.temperature, 21.6);
      expect(restored.temperatureLabel, '22℃');
      expect(restored.code, 61);
      expect(restored.updatedAt, snapshot.updatedAt);
      expect(restored.locationName, '上海');
    });
  });

  group('取数行为（注入假响应，不访问网络）', () {
    late WeatherService service;
    late List<Uri> requested;

    setUp(() {
      service = WeatherService.instance;
      requested = [];
    });

    tearDown(() {
      service.textLoader = null;
    });

    test('按经纬度请求 Open-Meteo，并带上当前天气所需字段', () async {
      service.textLoader = (uri) async {
        requested.add(uri);
        return '{"current":{"temperature_2m":26.1,"weather_code":0}}';
      };

      final snapshot = await service.fetchCurrent(
        latitude: 39.9042,
        longitude: 116.4074,
        locationName: '北京',
      );

      expect(requested, hasLength(1));
      expect(requested.single.host, 'api.open-meteo.com');
      expect(requested.single.queryParameters['latitude'], '39.9042');
      expect(requested.single.queryParameters['longitude'], '116.4074');
      expect(
        requested.single.queryParameters['current'],
        'temperature_2m,weather_code',
      );
      expect(requested.single.queryParameters['timezone'], 'auto');
      expect(snapshot!.temperatureLabel, '26℃');
      expect(snapshot.locationName, '北京');
    });

    test('请求失败（抛异常 / 返回垃圾数据）时返回 null，交给上层回退缓存', () async {
      service.textLoader = (uri) async => throw const SocketExceptionStub();
      expect(
        await service.fetchCurrent(latitude: 1, longitude: 2),
        isNull,
      );

      service.textLoader = (uri) async => '<html>502</html>';
      expect(
        await service.fetchCurrent(latitude: 1, longitude: 2),
        isNull,
      );
    });

    test('城市搜索返回候选坐标，空关键词不发请求', () async {
      service.textLoader = (uri) async {
        requested.add(uri);
        return '{"results":[{"name":"北京","admin1":"北京市",'
            '"country":"中国","latitude":39.9042,"longitude":116.4074},'
            '{"name":"北京镇","latitude":30.0,"longitude":120.0}]}';
      };

      final results = await service.searchCity('北京', count: 2);

      expect(requested.single.host, 'geocoding-api.open-meteo.com');
      expect(requested.single.queryParameters['name'], '北京');
      expect(requested.single.queryParameters['language'], 'zh');
      expect(results, hasLength(2));
      expect(results.first.latitude, 39.9042);
      expect(results.first.label, '北京 · 北京市 · 中国');
      expect(results.last.label, '北京镇');
    });

    test('城市搜索结果缺字段时安全降级，非法响应返回空列表', () {
      expect(WeatherService.parseGeocodeResponse('oops'), isEmpty);
      expect(WeatherService.parseGeocodeResponse('{}'), isEmpty);
      expect(
        WeatherService.parseGeocodeResponse(
          '{"results":[{"latitude":1,"longitude":2}]}',
        ),
        isEmpty,
      );
    });
  });
}

/// 仅用于让「注入的 loader 抛异常」这条用例不依赖 dart:io 的具体异常类型。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
