import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'backup_service.dart';

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
}

/// 基于 GitHub Releases 的自动更新服务。
///
/// 发版流程（见 .github/workflows/flutter.yml）：commit 首行 build: <版本> 推
/// main 后，CI 用版本号打 tag 创建 Release，并上传 release.zip（内容是
/// build/windows/x64/runner/Release 的全部文件）。本服务按同一约定取最新
/// Release 并安装。
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const String repoOwner = 'RuizeSun';
  static const String repoName = 'class_score';
  static const String latestReleaseUrl =
      'https://api.github.com/repos/' + repoOwner + '/' + repoName + '/releases/latest';

  /// 检查更新。
  ///
  /// 网络失败 / 接口异常 / 响应解析失败都返回 null，由调用方统一提示；
  /// 拿到结果时用 [UpdateCheckResult.updateAvailable] 判断是否需要弹窗。
  Future<UpdateCheckResult?> checkForUpdate() async {
    String currentVersion;
    try {
      final info = await PackageInfo.fromPlatform();
      currentVersion = info.version;
    } catch (_) {
      return null;
    }
    if (currentVersion.isEmpty) return null;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(latestReleaseUrl));
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      request.headers.set(HttpHeaders.userAgentHeader, 'class_score-updater');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await response.transform(utf8.decoder).join();
      return await parseLatestReleaseJson(body, currentVersion);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 下载并解析 release.zip.sha256 附件，返回小写十六进制哈希；失败返回空串。
  ///
  /// 兼容两种格式：裸哈希 / sha256sum 风格的「哈希  文件名」。任何一步失败都
  /// 当作没有校验文件处理（空串），由 [downloadRelease] 决定是否放行。
  static Future<String> fetchSha256Digest(String sha256Url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(sha256Url));
      request.headers.set(HttpHeaders.userAgentHeader, 'class_score-updater');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return '';
      final text = await response.transform(utf8.decoder).join();
      final match = RegExp(r'[0-9a-fA-F]{64}').firstMatch(text);
      return match == null ? '' : match.group(0)!.toLowerCase();
    } catch (_) {
      return '';
    } finally {
      client.close();
    }
  }

  /// 计算本地文件 sha256（十六进制小写）。
  static Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

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
      );
    } catch (_) {
      return null;
    }
  }

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

    // 2) 写更新脚本并脱离本进程启动：脚本等我们退出后再覆盖文件
    final helper = File(p.join(tempDirPath, 'update_helper.ps1'));
    await helper.writeAsString(_updaterScript);
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        helper.path,
        '-OldPid',
        pid.toString(),
        '-ExtractDir',
        extractDir,
        '-AppDir',
        appDir,
        '-ExeName',
        exeName,
      ],
      mode: ProcessStartMode.detached,
    );

    // 3) 让位：脚本在等本进程退出，直接结束（托盘图标由新进程重新注册）
    exit(0);
  }

  /// 覆盖式更新脚本：等待旧进程退出 -> 快照当前程序文件 -> 复制新文件 ->
  /// 重启。新版本若启动失败（30 秒内进程退出 / 没起来），自动把快照整包
  /// 复制回去恢复旧版本并重启，绝不把用户留在装坏了的状态。
  static const String _updaterScript = r'''
param(
    [int]$OldPid,
    [string]$ExtractDir,
    [string]$AppDir,
    [string]$ExeName
)
$ErrorActionPreference = 'Stop'
if ($OldPid -gt 0) { Wait-Process -Id $OldPid -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800

# release.zip 根目录直接是文件（CI 用 7z 压 Release/*）；万一将来包了一层目录也兼容
$source = $ExtractDir
$children = Get-ChildItem -LiteralPath $ExtractDir -Force
if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
    $source = $children[0].FullName
}

# ---- 冗余：快照当前程序文件（不含运行期数据）----
# data/（数据库）、backups/（备份）是运行期数据，不属于程序文件，跳过；
# 数据库另有更新前 VACUUM INTO 快照 + 3 分钟自动备份兜底。
$snapshotDir = Join-Path (Split-Path -Parent $ExtractDir) 'snapshot'
New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
$programFiles = Get-ChildItem -LiteralPath $AppDir -Force |
    Where-Object { $_.Name -notin @('data', 'backups') }
foreach ($f in $programFiles) { Copy-Item -LiteralPath $f.FullName -Destination $snapshotDir -Recurse -Force }

# ---- 覆盖式复制新版本（不删除任何旧文件）----
Copy-Item -Path (Join-Path $source '*') -Destination $AppDir -Recurse -Force

# ---- 启动新版本；若启动失败（30 秒内进程退出/没起来），整包回滚 ----
$newExe = Join-Path $AppDir $ExeName
Start-Process -FilePath $newExe
$proc = Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($ExeName)) -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -ne $OldPid } | Select-Object -First 1
$healthy = $false
if ($null -ne $proc) {
    $healthy = $true
    try { $proc.WaitForExit(30000) | Out-Null } catch {}
    if ($proc.HasExited) { $healthy = $false }
}

if (-not $healthy) {
    # 回滚：先结束残留的新进程，再把快照覆盖回去，重启旧版本
    Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($ExeName)) -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $OldPid } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    Copy-Item -Path (Join-Path $snapshotDir '*') -Destination $AppDir -Recurse -Force
    Start-Process -FilePath $newExe
}

Start-Sleep -Seconds 3
Remove-Item -LiteralPath (Split-Path -Parent $ExtractDir) -Recurse -Force -ErrorAction SilentlyContinue
''';
}
