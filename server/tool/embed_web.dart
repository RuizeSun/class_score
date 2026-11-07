import 'dart:convert';
import 'dart:io';

/// 把 `web/admin/` 下的静态文件嵌进 Dart 源码。
///
/// 单文件 exe 是这套服务端的部署形态：`dart compile exe` 只打包 Dart 代码，
/// 运行时再去磁盘上找 html/css/js 就要求"exe 旁边必须带着一个目录"，
/// 部署说明会立刻多出一步，而这一步一定会有人漏。
///
/// 用法（在 server/ 目录下）：
///   dart run tool/embed_web.dart
///
/// 忘跑工具的后果由 test/sync_admin_assets_test.dart 兜住：它逐字节比对
/// 生成的常量与磁盘文件，不一致直接失败。
void main() {
  final dir = Directory('web/admin');
  if (!dir.existsSync()) {
    stderr.writeln('找不到 web/admin/，请在 server/ 目录下运行');
    exitCode = 1;
    return;
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => _mimeFor(f.path) != null)
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final out = StringBuffer();
  out.writeln('// 由 tool/embed_web.dart 生成，请勿手改。');
  out.writeln('// 重新生成：cd server && dart run tool/embed_web.dart');
  out.writeln();
  out.writeln('/// 管理后台的静态资源：文件名 → 字节。');
  out.writeln('const Map<String, List<int>> adminAssets = {');
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final bytes = file.readAsBytesSync();
    out.writeln('  ${jsonEncode(name)}: <int>[');
    // 每行 16 个，读起来不至于一个文件占几百行
    for (var i = 0; i < bytes.length; i += 16) {
      final chunk = bytes.sublist(i, (i + 16).clamp(0, bytes.length));
      out.writeln('    ${chunk.join(', ')},');
    }
    out.writeln('  ],');
    stdout.writeln('  ${name.padRight(12)} ${bytes.length} 字节');
  }
  out.writeln('};');
  out.writeln();
  out.writeln('/// 按文件名给一个 content-type。');
  out.writeln('String adminAssetMime(String name) {');
  out.writeln('  if (name.endsWith(\'.css\')) return \'text/css; charset=utf-8\';');
  out.writeln('  if (name.endsWith(\'.js\')) return \'application/javascript; charset=utf-8\';');
  out.writeln('  return \'text/html; charset=utf-8\';');
  out.writeln('}');

  final target = File('lib/src/admin_assets.g.dart');
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(out.toString());
  stdout.writeln('已写入 ${target.path}');
}

String? _mimeFor(String path) {
  if (path.endsWith('.html')) return 'text/html';
  if (path.endsWith('.css')) return 'text/css';
  if (path.endsWith('.js')) return 'application/javascript';
  return null;
}
