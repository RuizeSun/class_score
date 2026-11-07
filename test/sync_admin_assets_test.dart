import 'dart:io';

import 'package:class_score_server/sync_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 静态资源是**生成**的：`server/web/admin/*` → `lib/src/admin_assets.g.dart`。
///
/// 单文件 exe 的部署形态要求把页面嵌进 Dart 代码里（见 tool/embed_web.dart）。
/// 生成方式的代价是容易漂移：改了 html 忘跑工具，服务端仍在发旧页面，
/// 而所有测试都还是绿的。这条测试就是那道闸。
void main() {
  test('嵌入的管理后台资源与磁盘文件逐字节一致', () {
    final dir = Directory(p.join('server', 'web', 'admin'));
    expect(
      dir.existsSync(),
      isTrue,
      reason: '找不到 server/web/admin/；测试需要在仓库根目录运行',
    );

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => _isAsset(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty);

    for (final file in files) {
      final name = p.basename(file.path);
      final embedded = adminAssets[name];
      expect(
        embedded,
        isNotNull,
        reason: '$name 没有嵌进去：请跑 cd server && dart run tool/embed_web.dart',
      );
      final onDisk = file.readAsBytesSync();
      expect(
        embedded,
        equals(onDisk),
        reason:
            '$name 与嵌入版本不一致（磁盘 ${onDisk.length} 字节 / '
            '嵌入 ${embedded!.length} 字节）：请重跑 embed_web.dart',
      );
    }

    // 反向：嵌入里不该有磁盘上已经删掉的文件
    for (final name in adminAssets.keys) {
      expect(
        files.any((f) => p.basename(f.path) == name),
        isTrue,
        reason: '$name 只存在于嵌入代码里，磁盘上已删除：请重跑 embed_web.dart',
      );
    }
  });

  test('每个资源都有可用的 content-type', () {
    for (final name in adminAssets.keys) {
      final mime = adminAssetMime(name);
      expect(mime, isNotEmpty);
      expect(mime, contains('charset=utf-8'), reason: '中文页面必须声明编码');
    }
    expect(adminAssetMime('index.html'), contains('text/html'));
    expect(adminAssetMime('admin.css'), contains('text/css'));
    expect(adminAssetMime('admin.js'), contains('javascript'));
  });

  test('页面引用的资源都在嵌入表里', () {
    final html = String.fromCharCodes(adminAssets['index.html']!);
    for (final match in RegExp(
      r'<(?:script|link)[^>]+(?:src|href)="([^"]+)"',
    ).allMatches(html)) {
      final ref = match.group(1)!;
      if (ref.startsWith('http') || ref.startsWith('data:')) continue;
      // 页面挂在 /admin 下，因此引用一律写成 /admin/xxx；嵌入表用文件名索引。
      final name = ref.startsWith('/admin/')
          ? ref.substring('/admin/'.length)
          : ref;
      expect(
        ref.startsWith('/admin/'),
        isTrue,
        reason: '\$ref 应当写成 /admin/ 开头的绝对路径（相对路径会 404）',
      );
      expect(
        adminAssets.containsKey(name),
        isTrue,
        reason: 'index.html 引用了 $ref，但它没有被嵌进去',
      );
    }
  });
}

bool _isAsset(String path) =>
    path.endsWith('.html') || path.endsWith('.css') || path.endsWith('.js');
