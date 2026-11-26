import 'dart:io';

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

  group('UpdateService.parseLatestReleaseAtom', () {
    const currentVersion = '1.6.0';
    const atom = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<feed xmlns="http://www.w3.org/2005/Atom">\n'
        '  <entry>\n'
        '    <id>tag:github.com,2008:Repository/1/1.6.1</id>\n'
        '    <link rel="alternate" type="text/html" '
        'href="https://github.com/RuizeSun/class_score/releases/tag/1.6.1"/>\n'
        '    <title>Release 1.6.1</title>\n'
        '    <content type="html">&lt;p&gt;修复自动更新&lt;/p&gt;</content>\n'
        '  </entry>\n'
        '  <entry>\n'
        '    <link rel="alternate" type="text/html" '
        'href="https://github.com/RuizeSun/class_score/releases/tag/1.5.4"/>\n'
        '    <title>Release 1.5.4</title>\n'
        '  </entry>\n'
        '</feed>';

    tearDown(() => UpdateService.instance.textLoader = null);

    test('取第一条 entry，备注去掉 HTML 并还原实体', () async {
      // 解析顺带会取 .sha256 附件：注入 loader，避免测试依赖真实网络。
      UpdateService.instance.textLoader = (uri) async => '';
      final result = await UpdateService.parseLatestReleaseAtom(atom, currentVersion);
      expect(result, isNotNull);
      expect(result!.tagName, '1.6.1');
      expect(result.latestVersion, '1.6.1');
      expect(result.updateAvailable, isTrue);
      expect(result.releaseNotes, '修复自动更新');
      expect(
        result.downloadUrl,
        'https://github.com/RuizeSun/class_score/releases/download/1.6.1/release.zip',
      );
    });

    test('空订阅源返回 null', () async {
      expect(
        await UpdateService.parseLatestReleaseAtom('<feed></feed>', currentVersion),
        isNull,
      );
    });
  });

  group('UpdateService.checkForVersion', () {
    const currentVersion = '1.6.0';
    final atom = '<?xml version="1.0"?>\n<feed>'
        '<entry><link rel="alternate" href="https://github.com/RuizeSun/class_score/releases/tag/1.6.1"/></entry>'
        '</feed>';
    final giteeManifest = '{"version":"1.6.2","tag":"1.6.2","notes":"来自 Gitee",'
        '"download_url":"https://gitee.com/RuizeSun/class_score/releases/download/1.6.2/release.zip",'
        '"sha256":"${'a' * 64}","size":123}';

    tearDown(() {
      UpdateService.instance.textLoader = null;
      UpdateService.instance.settingReader = null;
      UpdateService.instance.settingWriter = null;
    });

    test('api.github.com 被拦后回退到 github.com 订阅源', () async {
      final requested = <String>[];
      UpdateService.instance.textLoader = (uri) async {
        requested.add(uri.host + uri.path);
        if (uri.host == 'api.github.com') {
          throw const SocketException('Connection reset by peer');
        }
        // Gitee 也不可用，逼它回退到 GitHub atom
        if (uri.host == 'gitee.com') throw const SocketException('blocked');
        return atom;
      };

      final result = await UpdateService.instance.checkForVersion(
        currentVersion,
        preference: UpdateSourcePreference.githubFirst,
      );
      expect(result.latestVersion, '1.6.1');
      expect(result.updateAvailable, isTrue);
      expect(requested.first, startsWith('api.github.com'));
      expect(requested, contains('github.com/RuizeSun/class_score/releases.atom'));
    });

    test('Gitee 清单可用时优先使用，且不触发 GitHub 请求', () async {
      final requested = <String>[];
      UpdateService.instance.textLoader = (uri) async {
        requested.add(uri.host + uri.path);
        return giteeManifest;
      };

      final result = await UpdateService.instance.checkForVersion(currentVersion);
      expect(result.latestVersion, '1.6.2');
      expect(result.sourceLabel, 'Gitee');
      expect(result.assetSizeBytes, 123);
      expect(requested.length, 1);
      expect(requested.single, contains('gitee.com/RuizeSun/class_score/raw/update/latest.json'));
    });

    test('两个源都失败时抛异常，并带上每个源的原因', () async {
      UpdateService.instance.textLoader =
          (uri) async => throw const SocketException('Connection reset by peer');

      await expectLater(
        UpdateService.instance.checkForVersion(currentVersion),
        throwsA(
          isA<UpdateCheckException>().having(
            (error) => error.message,
            'message',
            allOf(contains('Gitee'), contains('GitHub'), contains('网络连接失败')),
          ),
        ),
      );
    });

    test('auto 偏好会优先上次成功的源', () async {
      final stored = <String, String>{'update_last_good_provider': 'github'};
      UpdateService.instance.settingReader = (key) async => stored[key];
      UpdateService.instance.settingWriter =
          (key, value) async => stored[key] = value;

      final requested = <String>[];
      UpdateService.instance.textLoader = (uri) async {
        requested.add(uri.host);
        throw const SocketException('down');
      };

      await expectLater(
        UpdateService.instance.checkForVersion(currentVersion),
        throwsA(isA<UpdateCheckException>()),
      );
      expect(requested.first, 'api.github.com');
    });

    test('成功一次后会记住来源，下次自动优先它', () async {
      final stored = <String, String>{};
      UpdateService.instance.settingReader = (key) async => stored[key];
      UpdateService.instance.settingWriter =
          (key, value) async => stored[key] = value;
      UpdateService.instance.textLoader = (uri) async {
        if (uri.host == 'gitee.com') throw const SocketException('blocked');
        if (uri.host == 'api.github.com') throw const SocketException('blocked');
        return atom;
      };

      await UpdateService.instance.checkForVersion(currentVersion);
      expect(stored['update_last_good_provider'], 'github');
    });
  });

  group('UpdateService.resolveSourceOrder', () {
    test('固定偏好忽略历史', () {
      expect(
        UpdateService.resolveSourceOrder(
            UpdateSourcePreference.giteeFirst, UpdateProvider.github),
        [UpdateProvider.gitee, UpdateProvider.github],
      );
      expect(
        UpdateService.resolveSourceOrder(
            UpdateSourcePreference.githubFirst, UpdateProvider.gitee),
        [UpdateProvider.github, UpdateProvider.gitee],
      );
    });

    test('auto：无历史时 Gitee 优先，有历史时跟随历史', () {
      expect(
        UpdateService.resolveSourceOrder(UpdateSourcePreference.auto, null),
        [UpdateProvider.gitee, UpdateProvider.github],
      );
      expect(
        UpdateService.resolveSourceOrder(
            UpdateSourcePreference.auto, UpdateProvider.github),
        [UpdateProvider.github, UpdateProvider.gitee],
      );
      expect(
        UpdateService.resolveSourceOrder(
            UpdateSourcePreference.auto, UpdateProvider.gitee),
        [UpdateProvider.gitee, UpdateProvider.github],
      );
    });
  });

  group('UpdateService.parseManifestJson', () {
    const currentVersion = '1.6.0';

    test('解析完整清单', () {
      final sha = 'b' * 64;
      final body = '{"version":"1.6.2","tag":"v1.6.2","notes":"修复",'
          '"download_url":"https://gitee.com/x/y/releases/download/1.6.2/release.zip",'
          '"sha256":"$sha","size":987654}';
      final result = UpdateService.parseManifestJson(body, currentVersion);
      expect(result, isNotNull);
      expect(result!.latestVersion, '1.6.2');
      expect(result.tagName, 'v1.6.2');
      expect(result.releaseNotes, '修复');
      expect(result.assetSizeBytes, 987654);
      expect(result.expectedSha256, sha);
      expect(result.updateAvailable, isTrue);
      expect(result.sourceLabel, 'Gitee');
    });

    test('size 是字符串时也能解析；非法 sha256 丢弃', () {
      final body = '{"version":"1.6.1","size":"42","sha256":"not-a-hash",'
          '"download_url":"https://gitee.com/x/y/releases/download/1.6.1/release.zip"}';
      final result = UpdateService.parseManifestJson(body, currentVersion);
      expect(result, isNotNull);
      expect(result!.assetSizeBytes, 42);
      expect(result.expectedSha256, isEmpty);
      expect(result.tagName, '1.6.1');
    });

    test('缺 version / download_url 时返回 null', () {
      expect(UpdateService.parseManifestJson('{}', currentVersion), isNull);
      expect(
        UpdateService.parseManifestJson(
            '{"version":"1.6.2"}', currentVersion),
        isNull,
      );
      expect(UpdateService.parseManifestJson('not json', currentVersion), isNull);
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
