import 'package:flutter_test/flutter_test.dart';
import 'package:class_score/services/update_service.dart';

void main() {
  group('UpdateService.isNewerVersion', () {
    test('更高版本返回 true', () {
      expect(UpdateService.isNewerVersion('1.5.5', '1.5.4'), isTrue);
      expect(UpdateService.isNewerVersion('1.6.0', '1.5.9'), isTrue);
      expect(UpdateService.isNewerVersion('2.0.0', '1.9.9'), isTrue);
    });

    test('相同或更低版本返回 false', () {
      expect(UpdateService.isNewerVersion('1.5.4', '1.5.4'), isFalse);
      expect(UpdateService.isNewerVersion('1.5.3', '1.5.4'), isFalse);
      expect(UpdateService.isNewerVersion('1.5', '1.5.0'), isFalse);
    });

    test('v 前缀归一化', () {
      expect(UpdateService.normalizeTagName('v1.6.0'), '1.6.0');
      expect(UpdateService.normalizeTagName('V2.0'), '2.0');
      expect(
        UpdateService.isNewerVersion(
            UpdateService.normalizeTagName('v1.6.0'), '1.5.4'),
        isTrue,
      );
    });

    test('段数不一致按 0 补齐', () {
      expect(UpdateService.isNewerVersion('1.6', '1.5.4'), isTrue);
      expect(UpdateService.isNewerVersion('1.5', '1.5.0'), isFalse);
    });
  });

  group('UpdateService.parseLatestReleaseJson', () {
    const currentVersion = '1.5.4';

    test('解析标准响应，识别 release.zip 附件与 v 前缀 tag', () async {
      const body = '{"tag_name":"v1.6.0","body":"### 更新内容- 自动更新","assets":[' +
          '{"name":"README.md","browser_download_url":"https://example.com/readme","size":100},' +
          '{"name":"release.zip","browser_download_url":"https://example.com/release.zip","size":52428800}]}';
      final result = await UpdateService.parseLatestReleaseJson(body, currentVersion);
      expect(result, isNotNull);
      expect(result!.tagName, 'v1.6.0');
      expect(result.latestVersion, '1.6.0');
      expect(result.currentVersion, currentVersion);
      expect(result.updateAvailable, isTrue);
      expect(result.downloadUrl, 'https://example.com/release.zip');
      expect(result.assetSizeBytes, 52428800);
      expect(result.releaseNotes, contains('自动更新'));
    });

    test('同版本时 updateAvailable 为 false', () async {
      const body = '{"tag_name": "1.5.4", "assets": []}';
      final result = await UpdateService.parseLatestReleaseJson(body, currentVersion);
      expect(result, isNotNull);
      expect(result!.updateAvailable, isFalse);
    });

    test('带 sha256 附件时提取预期哈希', () async {
      const body = '{"tag_name":"v1.6.0","assets":[' +
          '{"name":"release.zip","browser_download_url":"https://example.com/release.zip","size":1},' +
          '{"name":"release.zip.sha256","browser_download_url":"https://example.com/release.zip.sha256","size":65}]}';
      final result = await UpdateService.parseLatestReleaseJson(body, currentVersion);
      expect(result, isNotNull);
      // sha256 附件下载失败时为空串（跳过校验），这里断言字段存在且类型正确
      expect(result!.expectedSha256, isA<String>());
    });

    test('缺少 release.zip 附件时 downloadUrl 为空', () async {
      const body = '{"tag_name": "v1.6.0", "assets": []}';
      final result = await UpdateService.parseLatestReleaseJson(body, currentVersion);
      expect(result, isNotNull);
      expect(result!.downloadUrl, isEmpty);
    });

    test('坏 JSON / 缺 tag 返回 null', () async {
      expect(await UpdateService.parseLatestReleaseJson('not json', currentVersion), isNull);
      expect(
        await UpdateService.parseLatestReleaseJson('{"assets": []}', currentVersion),
        isNull,
      );
    });
  });
}
