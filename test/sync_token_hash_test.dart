import 'dart:convert';

import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// token 在服务端库里必须是**不可逆**的。
///
/// 这里曾经用 base64 当"哈希"：`base64Url.encode(utf8.encode('class_score::' + token))`。
/// base64 是编码不是哈希——拿到库就能直接解出明文 token 并登录。
/// 注释当时写的是"服务端只存哈希：库泄露也无法直接拿来登录"，与实现相反。
void main() {
  test('token 的存储形式不可逆：解不回原始 token', () {
    const token = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718';
    final stored = hashDeviceToken(token);

    // 1) 不是明文
    expect(stored.contains(token), isFalse, reason: '存储形式里不能出现明文 token');

    // 2) 不是可解码的编码：base64 解码必须失败，或解出来不含 token
    var recovered = <String>[];
    for (final decoder in [base64Url.decode, base64.decode]) {
      try {
        recovered.add(utf8.decode(decoder(stored)));
      } catch (_) {
        // 解不出来是期望行为
      }
    }
    for (final text in recovered) {
      expect(
        text.contains(token),
        isFalse,
        reason: '用 base64 解不出 token（当前实现曾经可以）',
      );
    }

    // 3) 同一个 token 必须得到同一个值（否则没法查表）
    expect(hashDeviceToken(token), stored);

    // 4) 不同 token 得到不同值
    expect(hashDeviceToken('another-token'), isNot(stored));
  });

  test('旧格式（base64）可以识别并迁移，已配对设备不用重新配对', () {
    const token = 'deadbeefdeadbeefdeadbeefdeadbeef';
    final legacy = base64Url.encode(utf8.encode('class_score::$token'));
    expect(isLegacyTokenHash(legacy), isTrue);
    expect(recoverLegacyToken(legacy), token, reason: '旧格式可逆，正好用来迁移');
    expect(hashDeviceToken(token), isNot(legacy));
  });
}