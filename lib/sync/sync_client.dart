import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:class_score_sync_protocol/class_score_sync_protocol.dart';
import 'package:flutter/foundation.dart';

/// HTTP 客户端：只做「把事件发出去 / 把事件取回来」。
///
/// 严格遵循仓库既有约定（见 weather_service.dart）：用 dart:io 的 HttpClient，
/// 不引入 dio/http 包；失败一律返回 null / 抛 [SyncException]，由上层决定重试。
class SyncClient {
  SyncClient({
    required this.baseUrl,
    required this.token,
    this.timeout = const Duration(seconds: 10),
    HttpClient? httpClient,
    List<int>? trustedCertificatePem,
  }) : _client = httpClient ?? HttpClient() {
    // 自签名证书：服务端是老师自己在一台机器上起的，不可能有公网 CA 签发。
    // 因此允许把服务端那张证书（PEM）显式信任下来。
    //
    // 注意这是**按内容固定一张证书**，不是"跳过校验"：
    // 只有与用户提供的那张逐字节相同的证书才会被接受，换一张就拒。
    final pem = trustedCertificatePem;
    if (pem == null) return;
    // 从 PEM 里取出证书的 DER 作为"固定指纹"：
    // 之后只接受 DER 与它逐字节相同的证书（换一张就拒），
    // 这不是"跳过校验"，而是"只信任这一张"。
    final pinned = _derFromPem(pem);
    if (pinned == null) {
      debugPrint('同步服务端证书无法解析，将拒绝连接');
      return;
    }
    _client.badCertificateCallback = (cert, host, port) {
      return _sameBytes(pinned, cert.der);
    };
  }

  /// 从 PEM 文本里解出第一张证书的 DER 字节。
  static List<int>? _derFromPem(List<int> pemBytes) {
    final text = String.fromCharCodes(pemBytes);
    final match = RegExp(
      r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
    ).firstMatch(text);
    if (match == null) return null;
    try {
      return base64Decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
    } catch (_) {
      return null;
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  final String baseUrl;
  final String token;
  final Duration timeout;
  final HttpClient _client;

  void close() => _client.close(force: true);

  /// 探活。离线时返回 false，不抛异常。
  Future<bool> health() async {
    try {
      final body = await _send('GET', SyncPaths.health);
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 设备配对：用一次性配对码换长期 token。
  Future<PairResult?> pair({
    required String code,
    required String deviceId,
    required String deviceName,
  }) async {
    try {
      final body = await _send(
        'POST',
        SyncPaths.pair,
        payload: {'code': code, 'device_id': deviceId, 'name': deviceName},
        authenticated: false,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;
      return PairResult(
        token: json['token'] as String,
        deviceId: json['device_id'] as String? ?? deviceId,
      );
    } catch (error) {
      debugPrint('同步配对失败：$error');
      return null;
    }
  }

  /// 推送一批事件。返回服务端应答；失败抛 [SyncException]。
  Future<PushResponse> push(List<SyncEvent> events) async {
    final body = await _send(
      'POST',
      SyncPaths.push,
      payload: {'events': events.map((e) => e.toJson()).toList()},
    );
    return PushResponse.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  /// 按游标拉取增量事件。
  Future<PullPage> pull({required int since, int limit = 500}) async {
    final body = await _send(
      'GET',
      '${SyncPaths.pull}?since=$since&limit=$limit',
    );
    final json = jsonDecode(body) as Map<String, dynamic>;
    final raw = (json['events'] as List?) ?? const [];
    return PullPage(
      events: raw
          .map((e) => SyncEvent.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      seq: (json['seq'] as num?)?.toInt() ?? since,
      hasMore: json['has_more'] == true,
    );
  }

  /// 全量对齐：拉取服务端上每行的最新状态。
  ///
  /// 与 [pull] 的区别是它不看游标、只回「当前值」，用于新设备首次接管、
  /// 或本地库被恢复备份之类导致游标与内容不匹配的场景。
  Future<PullPage> bootstrap() async {
    final body = await _send('GET', SyncPaths.bootstrap);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final raw = (json['events'] as List?) ?? const [];
    return PullPage(
      events: raw
          .map((e) => SyncEvent.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      hasMore: false,
    );
  }

  /// 轻量摘要：各表行数、事件条数、最大 rev。
  ///
  /// 首次配对时用它判断"服务端是不是空的"。失败抛 [SyncException]。
  Future<ServerSummary> summary() async {
    final body = await _send('GET', SyncPaths.summary);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final rawTables = (json['tables'] as Map?) ?? const {};
    return ServerSummary(
      liveRows: {
        for (final entry in rawTables.entries)
          entry.key as String:
              ((entry.value as Map)['live'] as num?)?.toInt() ?? 0,
      },
      eventCount: (json['event_count'] as num?)?.toInt() ?? 0,
      maxRev: (json['max_rev'] as num?)?.toInt() ?? 0,
    );
  }

  Future<String> _send(
    String method,
    String path, {
    Map<String, dynamic>? payload,
    bool authenticated = true,
  }) async {
    // 去掉尾斜杠：用户填 `http://host:8787/` 很常见，直接拼会得到
    // `//sync/pull`，shelf 路由匹配不上，表现为"配对失败：地址或配对码不正确"。
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$normalized$path');
    try {
      final request = await _client.openUrl(method, uri).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set('X-Sync-Protocol', '$syncProtocolVersion');
      if (authenticated && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (payload != null) {
        request.write(jsonEncode(payload));
      }
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode == 401) {
        throw const SyncException('unauthorized');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SyncException('http ${response.statusCode}: $body');
      }
      return body;
    } on SyncException {
      rethrow;
    } on TimeoutException {
      throw const SyncException('timeout');
    } catch (error) {
      throw SyncException('$error');
    }
  }
}

/// 服务端摘要。
class ServerSummary {
  const ServerSummary({
    required this.liveRows,
    required this.eventCount,
    required this.maxRev,
  });

  /// 每张表还活着的行数（不含墓碑）。
  final Map<String, int> liveRows;
  final int eventCount;

  /// 服务端事件里的最大 rev。本地初始上传要保证自己的 rev 比它大。
  final int maxRev;

  int get totalLiveRows => liveRows.values.fold(0, (a, b) => a + b);

  /// 服务端是不是一份数据都没有。
  bool get isEmpty => totalLiveRows == 0 && eventCount == 0;
}

/// 配对结果。
class PairResult {
  const PairResult({required this.token, required this.deviceId});
  final String token;
  final String deviceId;
}

/// 一次拉取的结果。
class PullPage {
  const PullPage({
    required this.events,
    required this.seq,
    required this.hasMore,
  });
  final List<SyncEvent> events;
  final int seq;
  final bool hasMore;
}

/// 同步过程中的可预期失败。上层只根据 [message] 决定是退避还是提示配对。
class SyncException implements Exception {
  const SyncException(this.message);
  final String message;

  bool get isUnauthorized => message == 'unauthorized';

  @override
  String toString() => 'SyncException($message)';
}
