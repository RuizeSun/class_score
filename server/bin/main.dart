import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:class_score_server/sync_server.dart';
import 'package:sqlite3/sqlite3.dart';

/// 服务端入口。
///
/// 用法：
///   dart run bin/main.dart --db data/server.db --port 8787
///   dart compile exe bin/main.dart -o class_score_server.exe
///
/// 首次部署：
///   1. 启动服务，控制台会打印一个配对码和一个管理员令牌；
///   2. 在 App 的「设置 → 同步服务」里填地址与该配对码；
///   3. 浏览器打开 http://127.0.0.1:8787/admin ，用管理员令牌登录后台。
///
/// 配对码是**一次性**的：第二台设备（比如老师的电脑）要接入时，
/// 在运行中的控制台敲一个回车即可再生成一个，不必重启服务。
/// 管理员令牌只在首次启动时打印一次，之后敲 T 可以轮换。
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('db', abbr: 'd', defaultsTo: 'data/server.db')
    ..addOption('host', defaultsTo: '0.0.0.0')
    ..addOption('port', abbr: 'p', defaultsTo: '8787')
    ..addOption('cert', help: 'TLS 证书链（PEM）；提供则启用 HTTPS')
    ..addOption('key', help: 'TLS 私钥（PEM）')
    ..addOption('admin-token', help: '用指定值作为管理员令牌（覆盖库里现有的）')
    ..addFlag('no-admin', negatable: false, help: '关闭内置管理后台')
    ..addFlag(
      'admin-allow-remote',
      negatable: false,
      help: '允许从非本机地址访问管理后台（默认只允许本机）',
    )
    ..addFlag('pair', defaultsTo: true, help: '启动时打印一次性配对码')
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args['help'] == true) {
    stdout.writeln(parser.usage);
    return;
  }

  final dbPath = args['db'] as String;
  final dir = Directory(File(dbPath).parent.path);
  if (!dir.existsSync()) dir.createSync(recursive: true);

  // TLS：给了证书和私钥就走 HTTPS。
  // 没给则保持明文 HTTP，并在下面打印明确警告——token 会以明文经过网络。
  SecurityContext? securityContext;
  final certPath = args['cert'] as String?;
  final keyPath = args['key'] as String?;
  if (certPath != null && keyPath != null) {
    securityContext = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath);
  }

  final db = openServerDb(dbPath);
  final adminEnabled = args['no-admin'] != true;
  final admin = AdminConfig(
    enabled: adminEnabled,
    allowRemote: args['admin-allow-remote'] == true,
  );

  // 管理员令牌：首次启动生成（只打印这一次），或按 --admin-token 覆盖。
  String? freshAdminToken;
  if (adminEnabled) {
    final given = (args['admin-token'] as String?)?.trim();
    if (given != null && given.isNotEmpty) {
      db.execute(
        'INSERT INTO admins(id, token_hash, created_at, rotated_at) '
        'VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
        'token_hash = excluded.token_hash, rotated_at = excluded.rotated_at',
        [
          'admin',
          hashSecret(given),
          DateTime.now().toIso8601String(),
          DateTime.now().toIso8601String(),
        ],
      );
      db.execute('DELETE FROM admin_sessions');
    } else {
      freshAdminToken = ensureAdminToken(db);
    }
  }

  // 事件日志只增不减，长期跑会一直涨。启动时按保留策略裁一次（保守策略，
  // 见 pruneEvents 的注释：只在超出阈值且超过保留窗口时才删）。
  final pruned = pruneEvents(db);
  if (pruned > 0) {
    stdout.writeln('  已裁剪 $pruned 条过期事件');
  }
  // 启动时把 WAL 合并回主库，避免 -wal 无限增长。
  try {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  } catch (_) {}

  final server = await serveSync(
    db: db,
    host: args['host'] as String,
    port: int.parse(args['port'] as String),
    securityContext: securityContext,
    admin: admin,
  );

  stdout.writeln('class_score sync server v1');
  stdout.writeln('  数据库: ${File(dbPath).absolute.path}');
  final scheme = securityContext != null ? 'https' : 'http';
  stdout.writeln(
    '  监听:   $scheme://${server.address.host}:${server.port}',
  );
  stdout.writeln('  已配对: ${listDevices(db).length} 台设备');
  if (securityContext == null) {
    stdout.writeln(adminWarning);
  }

  if (adminEnabled) {
    final scope = admin.allowRemote
        ? '允许非本机访问（--admin-allow-remote）'
        : '仅本机可访问';
    stdout.writeln(
      '  管理后台: $scheme://${server.address.host}:${server.port}/admin'
      '（$scope）',
    );
    final givenToken = (args['admin-token'] as String?)?.trim();
    if (freshAdminToken != null) {
      stdout.writeln('  管理员令牌: $freshAdminToken');
      stdout.writeln('    ↑ 只显示这一次。请立刻存进密码管理器。');
    } else if (givenToken != null && givenToken.isNotEmpty) {
      // 由 --admin-token 指定时不要把值再打一遍：它已经在启动脚本/环境里，
      // 写进日志只是多一处泄露面。
      stdout.writeln('  管理员令牌: 已按 --admin-token 设置');
    } else {
      stdout.writeln('  管理员令牌: 已存在（不知道就按 T 轮换）');
    }
  } else {
    stdout.writeln('  管理后台: 已关闭（--no-admin）');
  }

  if (args['pair'] == true) {
    _printCode(db);
  }

  // 优雅关闭。
  //
  // 之前没有任何信号处理：Ctrl+C 直接杀进程，WAL 不 checkpoint、未落盘的
  // 已提交事务靠 SQLite 自己的恢复，`-wal`/`-shm` 文件留在磁盘上越滚越大
  // （实测 server.db 4KB 时 -wal 已 337KB）。
  // 现在收到信号先停止接新连接、再做一次 checkpoint、最后 dispose。
  var shuttingDown = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (shuttingDown) return;
    shuttingDown = true;
    stdout.writeln('正在关闭（$signal）…');
    try {
      await server.close(force: false);
    } catch (_) {}
    try {
      // TRUNCATE 会把 WAL 合并回主库并清空 -wal file。
      db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {}
    try {
      db.dispose();
    } catch (_) {}
    stdout.writeln('  已关闭。');
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }

  stdout.writeln('  回车 = 再生成一个配对码；T = 轮换管理员令牌；Ctrl+C 退出');

  // 控制台交互：按行内容分流。
  //
  // 用 stdin.listen 而不是 await for：服务本身不等输入。stdin 被重定向到
  // /dev/null 时这条流会立刻结束，不报错、不占句柄；被当作后台服务启动时
  // 同理（正因为如此，这里不能按 hasTerminal 去 cancel —— 管道输入也是
  // 合法用法，运维脚本里常常就是这么发码的）。
  //
  // 之前只有"回车发码"这一种操作，现在多了 T（轮换令牌），所以必须
  // 按行内容判断，而不是"收到任何输入就发码"——否则一次误触就会
  // 把管理员令牌换掉。
  stdin.listen(
    (line) {
      final text = String.fromCharCodes(line).trim().toLowerCase();
      if (text == 't') {
        if (!adminEnabled) {
          stdout.writeln('  管理后台已关闭，无需令牌');
          return;
        }
        final token = rotateAdminToken(db);
        stdout.writeln('  管理员令牌已轮换: $token');
        stdout.writeln('    ↑ 旧令牌与所有已登录会话立即失效。');
        return;
      }
      if (text.isEmpty) _printCode(db);
    },
    onError: (Object _) {},
    cancelOnError: false,
  );
}

const String adminWarning =
    '  !! 未启用 HTTPS：配对码、设备 token 与管理员令牌都会以明文经过网络，\n'
    '     同一局域网内任何人都能截获并冒充设备或进入管理后台。\n'
    '     生产环境请用 --cert/--key 提供证书，或置于 HTTPS 反向代理之后。';

void _printCode(Database db) {
  final code = issuePairingCode(db);
  stdout.writeln('  配对码: $code（10 分钟内有效，一次性）');
}
