import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'backup_service.dart';
import 'heavy_compute.dart';

/// 更新包 / 版本信息的来源站点。
enum UpdateProvider {
  /// Gitee：`raw` 分支清单 + Release 附件，国内直连、不消耗 API 配额。
  gitee,

  /// GitHub：REST API 与 releases.atom 两级。
  github,
}

/// 检查更新时可选的来源偏好（设置页可选，默认自动）。
enum UpdateSourcePreference {
  /// 自动：优先上次成功的来源，另一个作为兜底（默认）。
  auto,

  /// 总是先试 Gitee，失败再试 GitHub。
  giteeFirst,

  /// 总是先试 GitHub，失败再试 Gitee。
  githubFirst,
}

/// 一次更新检查的结果。
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.tagName,
    required this.latestVersion,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.assetSizeBytes,
    required this.expectedSha256,
    required this.updateAvailable,
    this.sourceLabel = '',
  });

  /// 本机安装的版本（pubspec version，不含 build 号）。
  final String currentVersion;

  /// GitHub Release 的原始 tag（可能是 v1.6.0）。
  final String tagName;

  /// 归一化后的最新版本号（去掉 v 前缀）。
  final String latestVersion;

  /// Release 备注（body），直接展示在弹窗里。
  final String releaseNotes;

  /// release.zip 附件的 browser_download_url。
  final String downloadUrl;

  /// release.zip 的字节数（未知为 0）。
  final int assetSizeBytes;

  /// Release 附件 release.zip.sha256 里声明的哈希（为空 = 没有校验文件，跳过校验）。
  final String expectedSha256;

  /// 最新版本是否比当前版本新。
  final bool updateAvailable;

  /// 这次结果来自哪个源（展示用，例如 “Gitee” / “GitHub”）。
  final String sourceLabel;
}

/// 检查更新失败的原因（直接展示给用户）。
///
/// 以前所有分支都返回 null、界面统一提示「网络错误」，导致「到底是断网、
/// 域名被拦、接口限流还是响应变了」完全看不出来。现在把每一步的真实原因
/// 带出来，并在 [UpdateService.checkForUpdate] 里逐条汇总。
class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 基于 GitHub Releases（主）+ Gitee（国内镜像）的自动更新服务。
///
/// 发版流程（见 .github/workflows/flutter.yml）：commit 首行 build: <版本> 推
/// main 后，CI 用版本号打 tag 创建 Release，并上传 release.zip（内容是
/// build/windows/x64/runner/Release 的全部文件）；随后 Gitee 镜像 job 把同一
/// 份产物发到 Gitee，并在 `update` 分支写 `latest.json` 清单。
///
/// 三个数据源，按用户偏好排序后逐个尝试：
/// 1. Gitee `update` 分支的 `latest.json`（国内直连、不吃 API 限流）；
/// 2. `api.github.com/.../releases/latest`（信息最全，可带 asset 大小）；
/// 3. `github.com/.../releases.atom`（只有 tag 与备注，附件地址按命名规则推出）。
///
/// 为什么必须多源：`api.github.com`、`github.com`、`gitee.com` 是三台不同服务，
/// 校园网 / 一体机常见「网页能开 github.com，api.github.com 被 RST 秒断」，
/// 而匿名调 Gitee API 会被 `403 Rate Limit Exceeded` 限流——所以 Gitee 侧只
/// 用 `raw` 的静态清单，绝不调 API。
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const String repoOwner = 'RuizeSun';
  static const String repoName = 'class_score';

  /// Gitee 仓库（镜像），owner/repo 与 GitHub 保持一致。
  static const String giteeOwner = 'RuizeSun';
  static const String giteeRepo = 'class_score';

  static const String latestReleaseUrl =
      'https://api.github.com/repos/$repoOwner/$repoName/releases/latest';
  static const String releasesAtomUrl =
      'https://github.com/$repoOwner/$repoName/releases.atom';
  static const String releaseDownloadBase =
      'https://github.com/$repoOwner/$repoName/releases/download';

  /// Gitee 清单：`raw` 静态文件，匿名可读、不触发 API 限流。
  static const String giteeManifestUrl =
      'https://gitee.com/$giteeOwner/$giteeRepo/raw/update/latest.json';

  /// 单次请求超时：一体机 / 校园网里被丢包时也不能让界面无限转圈。
  static const Duration requestTimeout = Duration(seconds: 12);

  /// 记录上一次成功的来源，`auto` 偏好会优先复用（避免每次都等失败的超时）。
  static const String _lastGoodProviderKey = 'update_last_good_provider';

  /// 用户手动指定的来源顺序。
  static const String _sourcePreferenceKey = 'update_source_preference';

  /// 可注入的文本取用函数：默认真实网络请求，测试注入假响应以验证回退顺序。
  @visibleForTesting
  Future<String> Function(Uri uri)? textLoader;

  /// 读取 / 保存来源偏好与「上次可用源」的钩子；不注入则不持久化。
  @visibleForTesting
  Future<String?> Function(String key)? settingReader;
  @visibleForTesting
  Future<void> Function(String key, String value)? settingWriter;

  /// 接线到 app_settings（启动时调用一次；不接线则偏好只在本次运行内生效）。
  void bindSettings({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
  }) {
    settingReader = read;
    settingWriter = write;
  }

  /// 检查更新。任何一处失败都会抛 [UpdateCheckException] 并带上逐条原因，
  /// 由调用方原样展示（不要再改回「吞掉异常 + 统一网络错误」）。
  Future<UpdateCheckResult> checkForUpdate() async {
    final currentVersion = await _currentVersion();
    if (currentVersion.isEmpty) {
      throw const UpdateCheckException('无法读取本机版本号');
    }
    final preference = await _readSourcePreference();
    return checkForVersion(currentVersion, preference: preference);
  }

  /// [checkForUpdate] 的纯逻辑部分（版本号与偏好由调用方给），便于单测。
  @visibleForTesting
  Future<UpdateCheckResult> checkForVersion(
    String currentVersion, {
    UpdateSourcePreference preference = UpdateSourcePreference.auto,
  }) async {
    final lastGood = await _readLastGoodProvider();
    final order = resolveSourceOrder(preference, lastGood);

    final failures = <String>[];
    for (final provider in order) {
      try {
        final result = provider == UpdateProvider.gitee
            ? await _checkViaGitee(currentVersion)
            : await _checkViaGithub(currentVersion);
        await _writeLastGoodProvider(provider);
        return result;
      } catch (error) {
        failures.add('${_providerLabel(provider)}：${_describe(error)}');
      }
    }
    throw UpdateCheckException(
      '检查更新失败，请检查网络后重试（已尝试 ${failures.length} 个数据源）'
      '——${failures.join('；')}',
    );
  }

  /// 计算实际尝试顺序。
  ///
  /// - 固定偏好：按 `giteeFirst` / `githubFirst` 排；
  /// - 自动：上次成功的源优先，其余兜底；没有历史则 Gitee 优先（国内环境更常见）。
  @visibleForTesting
  static List<UpdateProvider> resolveSourceOrder(
    UpdateSourcePreference preference,
    UpdateProvider? lastGood,
  ) {
    switch (preference) {
      case UpdateSourcePreference.giteeFirst:
        return const [UpdateProvider.gitee, UpdateProvider.github];
      case UpdateSourcePreference.githubFirst:
        return const [UpdateProvider.github, UpdateProvider.gitee];
      case UpdateSourcePreference.auto:
        if (lastGood == UpdateProvider.github) {
          return const [UpdateProvider.github, UpdateProvider.gitee];
        }
        return const [UpdateProvider.gitee, UpdateProvider.github];
    }
  }

  static String _providerLabel(UpdateProvider provider) =>
      provider == UpdateProvider.gitee ? 'Gitee' : 'GitHub';

  Future<String> _currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version.trim();
    } catch (_) {
      return '';
    }
  }

  /// Gitee 清单（`latest.json`，由 CI 写入 update 分支）。
  Future<UpdateCheckResult> _checkViaGitee(String currentVersion) async {
    // 清单有 max-age=60 缓存：加时间戳确保拿到刚发布的版本。
    final url = '$giteeManifestUrl?_t=${DateTime.now().millisecondsSinceEpoch}';
    final body = await _get(url);
    final result = parseManifestJson(body, currentVersion);
    if (result == null) {
      throw const UpdateCheckException('清单无法解析（缺少 version？）');
    }
    return result;
  }

  /// GitHub：先 REST API，失败再退 atom。
  Future<UpdateCheckResult> _checkViaGithub(String currentVersion) async {
    try {
      final body =
          await _get(latestReleaseUrl, accept: 'application/vnd.github+json');
      final result = await parseLatestReleaseJson(body, currentVersion);
      if (result == null) {
        throw const UpdateCheckException('接口响应无法解析（没有 tag_name？）');
      }
      return result;
    } catch (apiError) {
      try {
        final body = await _get(releasesAtomUrl);
        final result = await parseLatestReleaseAtom(body, currentVersion);
        if (result != null) return result;
        throw const UpdateCheckException('订阅源无法解析（没有 entry？）');
      } catch (atomError) {
        throw UpdateCheckException(
          '${_describe(apiError)}；订阅源也失败：${_describe(atomError)}',
        );
      }
    }
  }

  /// 取回响应正文；非 200 与各类网络异常都转成带原因的 [UpdateCheckException]。
  Future<String> _get(String url, {String? accept}) async {
    final loader = textLoader;
    if (loader != null) return loader(Uri.parse(url));

    final client = HttpClient()..connectionTimeout = requestTimeout;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(requestTimeout);
      if (accept != null) {
        request.headers.set(HttpHeaders.acceptHeader, accept);
      }
      request.headers.set(HttpHeaders.userAgentHeader, 'class_score-updater');
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateCheckException(
          'HTTP ${response.statusCode}${_httpHint(response.statusCode)}',
        );
      }
      return await response.transform(utf8.decoder).join().timeout(requestTimeout);
    } finally {
      client.close(force: true);
    }
  }

  static String _httpHint(int statusCode) {
    if (statusCode == HttpStatus.forbidden || statusCode == HttpStatus.tooManyRequests) {
      return '（接口限流或拒绝访问）';
    }
    if (statusCode == HttpStatus.notFound) {
      return '（仓库、分支或文件不存在）';
    }
    return '';
  }

  /// 解析 Gitee `latest.json` 清单（由 CI 的镜像 job 生成）。
  ///
  /// 结构：
  /// ```json
  /// {"version":"1.6.2","tag":"1.6.2","notes":"...","download_url":"https://...",
  ///  "sha256":"...","size":13549456,"published_at":"..."}
  /// ```
  /// 只认 `version` 与 `download_url`，其余可缺省；解析失败返回 null。
  static UpdateCheckResult? parseManifestJson(
    String body,
    String currentVersion,
  ) {
    try {
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) return null;

      final rawVersion = (data['version'] as String?)?.trim() ?? '';
      if (rawVersion.isEmpty) return null;
      final downloadUrl = (data['download_url'] as String?)?.trim() ?? '';
      if (downloadUrl.isEmpty) return null;

      final tag = (data['tag'] as String?)?.trim() ?? rawVersion;
      final latest = normalizeTagName(rawVersion);
      // size 可能是数字也可能是字符串（不同手写/工具生成的清单都见过）
      final sizeValue = data['size'];
      final size = sizeValue is num
          ? sizeValue.toInt()
          : int.tryParse(sizeValue?.toString() ?? '') ?? 0;
      final sha = (data['sha256'] as String?)?.trim().toLowerCase() ?? '';

      return UpdateCheckResult(
        currentVersion: currentVersion,
        tagName: tag,
        latestVersion: latest,
        releaseNotes: data['notes'] as String? ?? '',
        downloadUrl: downloadUrl,
        assetSizeBytes: size,
        // 清单里的哈希只接受合法 64 位十六进制，格式不对就当没有
        expectedSha256: RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ? sha : '',
        updateAvailable: isNewerVersion(latest, currentVersion),
        sourceLabel: 'Gitee',
      );
    } catch (_) {
      return null;
    }
  }

  Future<UpdateSourcePreference> _readSourcePreference() async {
    final raw = await _readSetting(_sourcePreferenceKey);
    for (final value in UpdateSourcePreference.values) {
      if (value.name == raw) return value;
    }
    return UpdateSourcePreference.auto;
  }

  /// 读取用户选择的来源顺序（设置页展示用）。
  Future<UpdateSourcePreference> readSourcePreference() =>
      _readSourcePreference();

  /// 保存用户选择的来源顺序。
  Future<void> saveSourcePreference(UpdateSourcePreference preference) =>
      _writeSetting(_sourcePreferenceKey, preference.name);

  Future<UpdateProvider?> _readLastGoodProvider() async {
    final raw = await _readSetting(_lastGoodProviderKey);
    for (final value in UpdateProvider.values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  Future<void> _writeLastGoodProvider(UpdateProvider provider) async {
    final current = await _readLastGoodProvider();
    if (current == provider) return;
    await _writeSetting(_lastGoodProviderKey, provider.name);
  }

  Future<String?> _readSetting(String key) async {
    final reader = settingReader;
    if (reader == null) return null;
    try {
      return await reader(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSetting(String key, String value) async {
    final writer = settingWriter;
    if (writer == null) return;
    try {
      await writer(key, value);
    } catch (_) {}
  }

  /// 把异常翻译成人能看懂的一句话（原始信息保留在括号里）。
  static String _describe(Object error) {
    if (error is UpdateCheckException) return error.message;
    if (error is SocketException) {
      final detail = error.osError?.message ?? error.message;
      return '网络连接失败（$detail）';
    }
    if (error is TimeoutException) return '请求超时';
    if (error is HandshakeException) return 'TLS 握手失败（${error.message}）';
    return error.toString();
  }

  /// 下载并解析 release.zip.sha256 附件，返回小写十六进制哈希；失败返回空串。
  ///
  /// 兼容两种格式：裸哈希 / sha256sum 风格的「哈希  文件名」。任何一步失败都
  /// 当作没有校验文件处理（空串），由 [downloadRelease] 决定是否放行。
  static Future<String> fetchSha256Digest(String sha256Url) async {
    final loader = instance.textLoader;
    try {
      final text = loader != null
          ? await loader(Uri.parse(sha256Url))
          : await _getText(sha256Url);
      if (text == null) return '';
      final match = RegExp(r'[0-9a-fA-F]{64}').firstMatch(text);
      return match == null ? '' : match.group(0)!.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  /// 不带业务异常的取文辅助（校验文件取不到就当没有，不影响主流程）。
  static Future<String?> _getText(String url) async {
    final client = HttpClient()..connectionTimeout = requestTimeout;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(requestTimeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'class_score-updater');
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode != HttpStatus.ok) return null;
      return await response.transform(utf8.decoder).join().timeout(requestTimeout);
    } finally {
      client.close(force: true);
    }
  }

  /// 计算本地文件 sha256（十六进制小写）。
  ///
  /// 走后台 isolate：安装包十几兆，流式哈希在主 isolate 上也会让下载完成后的
  /// 那一帧明显卡顿。
  static Future<String> _sha256OfFile(File file) =>
      HeavyCompute.fileSha256(file.path);

  /// 解析 GitHub latest release 接口响应。解析失败返回 null。
  static Future<UpdateCheckResult?> parseLatestReleaseJson(
    String body,
    String currentVersion,
  ) async {
    try {
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) return null;
      final tag = (data['tag_name'] as String?)?.trim();
      if (tag == null || tag.isEmpty) return null;

      // 附件只认 release.zip 与 release.zip.sha256（与 CI 的打包约定一致）
      var downloadUrl = '';
      var sha256Url = '';
      var assetSize = 0;
      final assets = data['assets'];
      if (assets is List) {
        for (final asset in assets) {
          if (asset is! Map<String, dynamic>) continue;
          final name = asset['name'] as String? ?? '';
          if (name == 'release.zip') {
            downloadUrl = asset['browser_download_url'] as String? ?? '';
            assetSize = asset['size'] as int? ?? 0;
          } else if (name == 'release.zip.sha256') {
            sha256Url = asset['browser_download_url'] as String? ?? '';
          }
        }
      }

      final latest = normalizeTagName(tag);
      final expectedSha256 = sha256Url.isEmpty
          ? ''
          : await fetchSha256Digest(sha256Url);
      return UpdateCheckResult(
        currentVersion: currentVersion,
        tagName: tag,
        latestVersion: latest,
        releaseNotes: data['body'] as String? ?? '',
        downloadUrl: downloadUrl,
        assetSizeBytes: assetSize,
        expectedSha256: expectedSha256,
        updateAvailable: isNewerVersion(latest, currentVersion),
        sourceLabel: 'GitHub',
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 `releases.atom` 订阅源（api.github.com 不可用时的备用数据源）。
  ///
  /// atom 里没有附件清单，只能按 Release 命名约定推出：
  /// `releases/download/<tag>/release.zip`。因此拿不到附件大小，校验文件仍按
  /// 同一约定去取（取不到就跳过校验）。解析失败返回 null。
  static Future<UpdateCheckResult?> parseLatestReleaseAtom(
    String body,
    String currentVersion,
  ) async {
    try {
      final entries = RegExp(r'<entry>([\s\S]*?)</entry>').allMatches(body);
      for (final entry in entries) {
        final xml = entry.group(1) ?? '';
        final link = RegExp(r'<link[^>]*href="([^"]+)"').firstMatch(xml);
        final href = link?.group(1) ?? '';
        final tag = href.split('/').where((part) => part.isNotEmpty).lastOrNull;
        if (tag == null || tag.isEmpty) continue;

        final content = RegExp(r'<content[^>]*>([\s\S]*?)</content>').firstMatch(xml);
        final notes = _unescapeXml(content?.group(1) ?? '').trim();
        final downloadUrl = '$releaseDownloadBase/$tag/release.zip';
        final latest = normalizeTagName(tag);
        return UpdateCheckResult(
          currentVersion: currentVersion,
          tagName: tag,
          latestVersion: latest,
          releaseNotes: notes,
          downloadUrl: downloadUrl,
          assetSizeBytes: 0,
          expectedSha256: await fetchSha256Digest('$downloadUrl.sha256'),
          updateAvailable: isNewerVersion(latest, currentVersion),
          sourceLabel: 'GitHub',
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// atom 的 `<content type="html">` 是转义过的：还原常用实体，去掉标签。
  static String _unescapeXml(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'<[^>]*>'), ' ');

  /// v1.6.0 / V1.6.0 / 1.6.0 -> 1.6.0。
  static String normalizeTagName(String tag) {
    var value = tag.trim();
    while (value.isNotEmpty && (value.startsWith('v') || value.startsWith('V'))) {
      value = value.substring(1);
    }
    return value.trim();
  }

  /// 按点分数字段比较版本号：isNewerVersion('1.6.0', '1.5.4') == true。
  ///
  /// 缺失的段按 0 处理（1.6 与 1.6.0 等价）；非数字段按 0。
  static bool isNewerVersion(String candidate, String current) {
    final a = _versionParts(candidate);
    final b = _versionParts(current);
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static List<int> _versionParts(String version) => normalizeTagName(version)
      .split('.')
      .map((part) => int.tryParse(part.trim()) ?? 0)
      .toList();

  /// 下载 release.zip 到系统临时目录，返回 zip 文件。
  ///
  /// [onProgress] 上报已接收字节数与总字节数（总大小未知时为 null）。
  /// 下载失败会清理临时目录后原样抛出。
  Future<File> downloadRelease(
    UpdateCheckResult update, {
    void Function(int received, int? totalBytes)? onProgress,
  }) async {
    if (update.downloadUrl.isEmpty) {
      throw Exception('该版本没有找到 release.zip 附件');
    }
    final tempDir = await Directory.systemTemp.createTemp('class_score_update');
    final savePath = p.join(tempDir.path, 'release.zip');
    var received = 0;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(update.downloadUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'class_score-updater');
      // GitHub 附件会 302 到 objects.githubusercontent.com，HttpClient 默认跟随
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('下载失败（HTTP ' + response.statusCode.toString() + '）');
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      final sink = File(savePath).openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      onProgress?.call(received, total);

      // 完整性校验：Release 带了 sha256 附件就必须对得上，不对拒装。
      if (update.expectedSha256.isNotEmpty) {
        final digest = await _sha256OfFile(File(savePath));
        if (digest != update.expectedSha256) {
          throw Exception(
            '更新包校验失败（sha256 不匹配），已放弃安装。'
            '预期：\${update.expectedSha256}，实际：\$digest',
          );
        }
      }
      return File(savePath);
    } catch (error) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  /// 更新安装前的最后一道保险：强制给数据库做一份一致性快照（VACUUM INTO，
  /// 不经过 3 分钟节流）。失败不阻塞更新（数据另有 3 分钟一次的自动备份兜底），
  /// 只记日志。
  static Future<void> createPreUpdateBackup() async {
    try {
      final path = await BackupService.instance.createBackup(force: true);
      debugPrint('更新前数据库备份：' + (path ?? '失败（沿用自动备份）'));
    } catch (error) {
      debugPrint('更新前数据库备份失败：' + error.toString());
    }
  }

  /// 安装更新：解压 -> 写独立更新脚本 -> 启动脚本后立刻退出本进程。
  ///
  /// 更新脚本（PowerShell，独立进程）等待本进程退出后，把新版本文件覆盖式
  /// 复制到安装目录（不删除任何旧文件，data/score.db 等运行期数据不受影响），
  /// 然后重新启动应用并清理临时目录。
  ///
  /// 成功时本方法不会返回（进程已退出）；失败抛异常，由调用方展示错误。
  Future<void> installUpdate(File zip) async {
    final exePath = Platform.resolvedExecutable;
    final appDir = p.dirname(exePath);
    final exeName = p.basename(exePath);
    final tempDirPath = p.dirname(zip.path);
    final extractDir = p.join(tempDirPath, 'extracted');

    // 1) 解压（PowerShell Expand-Archive，Windows 自带，不引入依赖）
    final expand = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'Expand-Archive -LiteralPath "' + zip.path + '" -DestinationPath "' + extractDir + '" -Force',
      ],
    );
    if (expand.exitCode != 0) {
      throw Exception('解压更新包失败：' + expand.stderr.toString());
    }

    // 2) 写更新脚本：必须带 UTF-8 BOM（PowerShell 5.1 否则按 GBK 解析，
    //    会把中文注释后的换行吞掉、让脚本静默失效）。
    // 脚本放在系统临时目录根而不是 TempDir 里：执行中的 .ps1 会被占用，
    // 放在 TempDir 内会导致收尾删不掉整个临时目录（实测残留）。
    final helper = File(
      p.join(Directory.systemTemp.path, 'class_score_update_helper.ps1'),
    );
    await helper.writeAsBytes(
      <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(_updaterScript)],
      flush: true,
    );

    // 3) 启动更新脚本。注意不能用 ProcessStartMode.detached：Windows 下
    //    DETACHED_PROCESS 的 PowerShell 会直接空跑退出（不写日志、不执行），
    //    实测 helper 完全没跑起来。普通启动后立即排空管道，脚本自身不依赖父进程，
    //    本进程退出后它会继续完成替换与重启。
    // 只有我们自己创建的临时目录才允许脚本收尾时删除；防呆：万一传入的 zip
    // 在别处（例如 %TEMP% 根），清理会把整个目录删掉。
    final ownsTempDir = p.basename(tempDirPath).startsWith('class_score_update');
    final helperProcess = await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        helper.path,
        '-OldPid',
        pid.toString(),
        '-TempDir',
        tempDirPath,
        '-ExtractDir',
        extractDir,
        '-AppDir',
        appDir,
        '-ExeName',
        exeName,
        if (ownsTempDir) '-Cleanup',
      ],
      // 工作目录不能用 tempDirPath：进程 CWD 指向该目录时 Windows 拒绝删除它，
      // 收尾清理会失败、留下空目录（实测）。
      workingDirectory: Directory.systemTemp.path,
    );
    unawaited(helperProcess.stdout.drain<void>());
    unawaited(helperProcess.stderr.drain<void>());

    // 4) 确认脚本真的跑起来了（编码 / 执行策略 / 路径问题的第一现场）：
    //    等它写 BEGIN 日志；超时或有 ERROR 就取消本次更新，应用保持运行。
    final logFile = File(p.join(tempDirPath, 'update_helper.log'));
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      String text;
      try {
        if (!await logFile.exists()) continue;
        text = await logFile.readAsString();
      } catch (_) {
        continue;
      }
      if (text.contains('ERROR')) {
        throw Exception('更新脚本执行失败：' + text.trim());
      }
      if (text.contains('BEGIN')) {
        // 脚本已经接管：退出，让它在后台替换文件并重启
        exit(0);
      }
    }
    throw Exception('更新脚本未能启动，已取消本次更新（应用保持运行）');
  }

  /// 更新脚本：等待旧进程退出 -> 快照当前程序文件 -> 覆盖新文件 -> 启动并
  /// 监视新版本（30 秒内退出即整包回滚重启旧版）。
  ///
  /// 注意：脚本必须是纯 ASCII 并带 UTF-8 BOM 写入。PowerShell 5.1 读无 BOM 的
  /// 脚本时按系统 ANSI(GBK) 解码，中文注释里的字节会吞掉换行、把后续语句并进
  /// 注释，导致脚本静默失效（1.6.0 就是这么踩的）。日志写到 update_helper.log。
  static const String _updaterScript = r'''
param(
    [int]$OldPid = 0,
    [string]$TempDir,
    [string]$ExtractDir,
    [string]$AppDir,
    [string]$ExeName,
    [switch]$Cleanup
)
$ErrorActionPreference = 'Stop'
$logPath = Join-Path $TempDir 'update_helper.log'
function Write-Log([string]$m) {
    try { Add-Content -LiteralPath $logPath -Value ((Get-Date).ToString('o') + ' ' + $m) } catch {}
}
Write-Log ('BEGIN oldpid=' + $OldPid + ' app=' + $AppDir + ' exe=' + $ExeName)
try {
    if ($OldPid -gt 0) {
        Write-Log 'WAIT old process'
        Wait-Process -Id $OldPid -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800

    # release.zip root holds files directly (CI packs Release/*); accept one wrapping folder too
    $source = $ExtractDir
    $children = @(Get-ChildItem -LiteralPath $ExtractDir -Force)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) { $source = $children[0].FullName }
    Write-Log ('SOURCE ' + $source)

    # snapshot current program files (skip runtime data: data/, backups/)
    $snapshotDir = Join-Path $TempDir 'snapshot'
    if (Test-Path $snapshotDir) { Remove-Item -LiteralPath $snapshotDir -Recurse -Force }
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    $programFiles = @(Get-ChildItem -LiteralPath $AppDir -Force | Where-Object { $_.Name -notin @('data', 'backups') })
    foreach ($f in $programFiles) {
        Copy-Item -LiteralPath $f.FullName -Destination $snapshotDir -Recurse -Force
    }
    Write-Log ('SNAPSHOT files=' + $programFiles.Count)

    Copy-Item -Path (Join-Path $source '*') -Destination $AppDir -Recurse -Force
    Write-Log 'COPIED'

    $newExe = Join-Path $AppDir $ExeName
    $proc = $null
    try { $proc = Start-Process -FilePath $newExe -WorkingDirectory $AppDir -PassThru } catch {
        Write-Log ('START_FAILED ' + $_.Exception.Message)
    }
    $healthy = $false
    if ($null -ne $proc) {
        Write-Log ('STARTED pid=' + $proc.Id)
        $healthy = $true
        try { $proc.WaitForExit(30000) | Out-Null; if ($proc.HasExited) { $healthy = $false } } catch {}
    }
    Write-Log ('HEALTH ' + $healthy)
    if (-not $healthy) {
        Write-Log 'ROLLBACK'
        if ($null -ne $proc) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {} }
        Start-Sleep -Milliseconds 800
        Copy-Item -Path (Join-Path $snapshotDir '*') -Destination $AppDir -Recurse -Force
        try {
            $restored = Start-Process -FilePath $newExe -WorkingDirectory $AppDir -PassThru
            Write-Log ('ROLLED_BACK restarted pid=' + $restored.Id)
        } catch {
            Write-Log ('ROLLBACK_START_FAILED ' + $_.Exception.Message)
        }
    } else {
        Write-Log 'ROLLED_FORWARD'
    }
    Write-Log 'DONE'
} catch {
    Write-Log ('ERROR ' + $_.Exception.Message)
    throw
}
# keep a copy of the log outside the temp dir for post-mortem, then clean up
try { Copy-Item -LiteralPath $logPath -Destination (Join-Path $env:TEMP 'class_score_update_last.log') -Force } catch {}
Write-Log ('CLEANUP_START ' + $Cleanup + ' dir=' + $TempDir)
if ($Cleanup) {
    Start-Sleep -Seconds 2
    $removed = $false
    for ($i = 0; $i -lt 8; $i++) {
        try { Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction Stop; $removed = $true; break } catch {}
        Start-Sleep -Seconds 1
    }
    if (-not $removed) {
        Write-Log 'CLEANUP_PS_FAILED try rd'
        cmd /c rd /s /q "$TempDir" 2>$null
    }
    Write-Log ('CLEANUP_DONE exists=' + (Test-Path $TempDir))
}
''';
}
