import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 桌面课表浮窗的排查日志（写文件）。
///
/// 为什么必须写文件：浮窗跑在独立 Flutter 引擎里，它的 `debugPrint` 在
/// `flutter run` 下通常不会出现在控制台——出问题时我们只能看到主窗口那一半
/// 日志，无法判断「浮窗的 Dart 到底有没有跑起来」。
/// 两个引擎都往同一个 `data/desktop_bar_debug.log` 追加，就能得到一条合并的
/// 时间线；日志失败时静默降级（绝不因为日志问题影响桌面条本身）。
class DesktopBarLog {
  DesktopBarLog._();

  static const String fileName = 'desktop_bar_debug.log';

  /// 日志体积上限：超过后重开一份，避免长期运行把文件撑大。
  static const int _maxBytes = 256 * 1024;

  static File? _file;
  static bool _disabled = false;

  /// 记录一条日志；`tag` 用来区分是哪个窗口写的（main / bar）。
  static Future<void> write(String tag, String message) async {
    if (_disabled) return;
    try {
      if (_file == null) {
        // 浮窗不打开数据库，因此这里要自己保证 data/ 存在（主窗口通常已创建）。
        final dir = Directory(_dataDir());
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        _file = File(p.join(dir.path, fileName));
      }
      final file = _file!;
      if (await file.exists() && await file.length() > _maxBytes) {
        await file.writeAsString(
          '${DateTime.now().toIso8601String()} [system] 日志超过 '
          '${_maxBytes ~/ 1024}KB，重新开始记录\n',
        );
      }
      await file.writeAsString(
        '${DateTime.now().toIso8601String()} [$tag] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (error) {
      _disabled = true;
      debugPrint('桌面课表日志写入失败：$error');
    }
  }

  /// 日志与被打开的数据库同目录（exe 旁的 data/），与 `DatabaseHelper.dbDir` 一致。
  static String _dataDir() =>
      p.join(p.dirname(Platform.resolvedExecutable), 'data');
}
