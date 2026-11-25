import 'dart:async';
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
