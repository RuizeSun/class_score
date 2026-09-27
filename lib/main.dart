import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:window_manager/window_manager.dart';
import 'models/desktop_ball_style.dart';
import 'pages/desktop_bar/desktop_bar_window.dart';
import 'services/app_shell_service.dart';
import 'services/desktop_ball_service.dart';
import 'services/desktop_bar_log.dart';
import 'services/desktop_window_service.dart';
import 'services/tray_service.dart';
import 'services/window_service.dart';
import 'widgets/desktop_schedule/desktop_schedule_common.dart';
import 'providers/group_provider.dart';
import 'providers/student_provider.dart';
import 'providers/score_provider.dart';
import 'providers/score_item_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/personalization_provider.dart';
import 'providers/desktop_schedule_provider.dart';
import 'pages/core/home_page.dart';
import 'pages/core/pin_setup_page.dart';
import 'widgets/motion.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面课表浮窗是 desktop_multi_window 创建的第二个引擎，需要走完全不同的
  // 启动路径（不初始化主窗口、不读数据库，只渲染主窗口推过来的状态）。
  if (await _isDesktopBarEngine(args)) {
    await DesktopBarLog.write(
      DesktopWindowService.barTag,
      '浮窗引擎启动，入口参数=$args',
    );
    runApp(DesktopBarWindow(launchArguments: args));
    return;
  }

  await DesktopBarLog.write(
    DesktopWindowService.mainTag,
    '主窗口启动，入口参数=$args',
  );
  await WindowService.setup();
  runApp(const MyApp());
}

/// 判断本引擎是不是桌面条浮窗。
///
/// 两重判据：
/// 1. `desktop_multi_window` 给新引擎注入的入口参数 `['multi_window', id, 参数]`
///    —— 这是最直接的证据；
/// 2. 直接问插件「我是哪个窗口」（官方 example 的做法）：主窗口的 `arguments`
///    是空串，浮窗则是我们创建时写入的 [DesktopWindowService.barWindowArgument]。
///
/// 保守原则：只要入口参数出现 `multi_window` 前缀、但身份仍无法确认，也一律
/// 按浮窗处理——**宁可浮窗空着，也绝不能在子窗口里再跑一遍完整主程序**：那会
/// 读同一份设置（桌面课表开关＝开）再建一个浮窗，窗口无限递归。
Future<bool> _isDesktopBarEngine(List<String> args) async {
  final hasMultiWindowPrefix =
      args.isNotEmpty &&
      args.first == DesktopWindowService.multiWindowEntrypoint;

  if (DesktopWindowService.isBarWindow(args)) return true;

  try {
    final controller = await WindowController.fromCurrentEngine();
    if (controller.arguments == DesktopWindowService.barWindowArgument) {
      return true;
    }
  } catch (error) {
    await DesktopBarLog.write(
      DesktopWindowService.mainTag,
      '无法从插件确认窗口身份：$error',
    );
  }

  return hasMultiWindowPrefix;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PersonalizationProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => GroupProvider()),
        ChangeNotifierProvider(create: (_) => StudentProvider()),
        ChangeNotifierProvider(create: (_) => ScoreProvider()),
        ChangeNotifierProvider(create: (_) => ScoreItemProvider()),
        ChangeNotifierProvider(create: (_) => DesktopScheduleProvider()),
      ],
      child: const AppBody(),
    );
  }
}

/// Separate widget so it can watch PersonalizationProvider for dynamic theme.
class AppBody extends StatefulWidget {
  const AppBody({super.key});

  @override
  State<AppBody> createState() => _AppBodyState();
}

class _AppBodyState extends State<AppBody> {
  @override
  Widget build(BuildContext context) {
    final personalization = context.watch<PersonalizationProvider>();

    return MaterialApp(
      title: '班级量化评分管理',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: personalization.seedColor),
        useMaterial3: true,
      ),
      home: const AppEntry(),
    );
  }
}

class AppEntry extends StatefulWidget {
  const AppEntry({super.key});

  @override
  State<AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<AppEntry> with WindowListener {
  DesktopScheduleProvider? _desktop;
  AuthProvider? _auth;

  bool _barVisible = false;

  /// 防止「配置 + 推内容」在连续的 notify 下并发重入。
  bool _syncingBar = false;
  bool _barSyncPending = false;

  /// 下一次允许尝试创建浮窗的时间（失败退避，避免每秒重试刷屏）。
  DateTime _nextBarAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 悬浮球最近一次推给原生的配置签名；null = 球当前是关闭的（窗口不存在）。
  String? _ballSignature;

  /// 悬浮球推送的并发保护（窗口事件与每秒的状态推送可能同时进来）。
  bool _syncingBall = false;
  bool _ballSyncPending = false;

  /// 主窗口是否正显示在屏幕上（未最小化、未收进托盘）。
  ///
  /// 初值取 true：启动时窗口马上就会显示，先按「在屏上」算，球不会先闪一下
  /// 再被收起来。
  bool _appOnScreen = true;

  /// 是否已经真正观察到过一次「窗口在屏上」。
  ///
  /// 启动瞬间主窗口还没 `Show()`（runner 要等首帧渲染完才显示窗口），这时探测
  /// 会得到「不在屏上」；直接采信的话球会先淡入、几十毫秒后再被收回去。所以
  /// 只有在见过窗口在屏上之后，才允许把「不在屏上」当真。
  bool _appOnScreenSeen = false;

  /// 显隐查询失败只记一次日志：状态每秒刷新，一直失败会把日志刷爆。
  bool _loggedOnScreenFailure = false;

  /// 最近一次已记录的球的显隐，用于只在翻转时写一行日志。
  bool? _loggedBallVisible;

  /// 球此刻是否应当出现在屏幕上（开关关掉时不算：那种时候球窗口会被销毁、
  /// 让位也归零）。
  ///
  /// 由 [_refreshBallOnScreen] 在每一拍开头刷新，供 [_pushDesktopBall]（球窗口的
  /// 显隐）与 [DesktopScheduleProvider.toBarPayload]（胶囊的让位）共用。
  bool _ballShown = false;

  /// 托盘图标当前是否已显示：主题色之类的无关通知不该反复过通道。
  bool? _trayEnabled;

  @override
  void initState() {
    super.initState();
    // 主窗口「在屏上 / 收进托盘 / 最小化」一变就立刻同步球：事件来自真实窗口
    // 过程（WM_SIZE / WM_SHOWWINDOW），比每秒的状态推送及时得多。
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 先把 Provider 取出来：下面有 await，之后再碰 context 会触发
      // use_build_context_synchronously（而且 widget 也可能已被销毁）。
      final personalization = context.read<PersonalizationProvider>();
      final auth = context.read<AuthProvider>();
      final desktop = context.read<DesktopScheduleProvider>();

      personalization.init();
      auth.init();
      context.read<ScoreProvider>().init();
      // 首帧后按真实非客户区再校准一次窗口尺寸，确保内容区为 1280x800。
      await WindowService.refresh();

      // 托盘与悬浮球的原生事件接线：两个通道都由 Windows runner 注册
      // （见 windows/runner/flutter_window.cpp），其它平台会在服务内部
      // 以 MissingPluginException 静默降级成日志。
      // 菜单里的「退出程序」不在其中：由原生直接结束进程（app_quit.cpp）。
      TrayService.attach(
        onShow: AppShellService.showMainWindow,
        onHide: AppShellService.hideMainWindow,
      );
      DesktopBallService.attach(
        onShow: AppShellService.showMainWindow,
        onHide: AppShellService.hideMainWindow,
        onMoved: desktop.setBallOffset,
      );
      personalization.addListener(_syncTrayIcon);
      _syncTrayIcon();

      // 桌面课表：课表数据来自 AuthProvider，状态机与配置在 DesktopScheduleProvider，
      // 这里只做两者的接线与「把状态推给浮窗」。
      _desktop = desktop;
      _auth = auth;
      auth.addListener(_syncSchedulesToDesktop);
      desktop.addListener(_syncDesktopBar);
      _syncSchedulesToDesktop();
      await desktop.init();
      await _syncDesktopBar();
    });
  }

  /// 托盘图标跟着「关闭窗口时最小化到托盘」设置走：关掉设置连图标一起收掉
  /// （关闭就变成真正退出，留着图标反而误导）。
  void _syncTrayIcon() {
    if (!mounted) return;
    final enabled = context.read<PersonalizationProvider>().closeToTray;
    if (_trayEnabled == enabled) return;
    _trayEnabled = enabled;
    unawaited(TrayService.setEnabled(enabled));
  }

  void _syncSchedulesToDesktop() {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    _desktop?.updateSchedules(
      auth.courseSchedules,
      auth.scheduleAdjustments,
    );
  }

  /// 按设置把桌面条窗口「显示 / 隐藏 / 重新配置」，并推送最新内容。
  Future<void> _syncDesktopBar() async {
    final desktop = _desktop;
    if (desktop == null) return;

    // 状态每秒都会通知，这里用「挂起标记」合并调用：正在同步时再来一次，
    // 只标记待处理，结束后补一次即可，避免每秒钟排队多个窗口调用。
    if (_syncingBar) {
      _barSyncPending = true;
      return;
    }
    _syncingBar = true;
    try {
      // 球此刻是否在屏上要在推内容之前算好：它同时决定胶囊的让位（球藏起来时
      // 让位归零，胶囊才真正居中），内容与球必须在同一拍里用同一个结果。
      await _refreshBallOnScreen();
      do {
        _barSyncPending = false;
        if (!desktop.enabled) {
          if (_barVisible) {
            _barVisible = false;
            await DesktopWindowService.log('桌面课表已关闭，隐藏浮窗');
            await DesktopWindowService.hideBar();
          }
          // 重新开启时立刻尝试创建，不用等退避
          _nextBarAttempt = DateTime.fromMillisecondsSinceEpoch(0);
          continue;
        }

        // 浮窗可能被外部关掉（任务管理器 / 系统回收），此时要重新创建，
        // 否则会出现「设置里显示已开启、桌面上却没有条」。
        if (_barVisible && !await DesktopWindowService.barExists()) {
          _barVisible = false;
        }

        if (!_barVisible) {
          // 创建失败后退避重试：状态每秒刷新一次，不退避就会每秒重试 + 刷屏。
          if (DateTime.now().isBefore(_nextBarAttempt)) continue;
          _nextBarAttempt = DateTime.now().add(
            DesktopWindowService.retryBackoff,
          );
          await DesktopWindowService.logWindowList();
          _barVisible = await DesktopWindowService.showBar();
        }

        if (_barVisible) {
          // 外观参数（位置 / 层级 / 穿透 / 透明度 / 缩放 / 球的让位）一并放在
          // 内容快照里，浮窗发现变化时再调原生通道应用，主窗口不需要额外的
          // 配置通道。
          await DesktopWindowService.pushBarPayload(
            desktop.toBarPayload(ballVisible: _ballShown),
          );
        }
      } while (_barSyncPending);

      // 球的落点取决于「胶囊是否真的在屏上」，必须等这一拍结束后再推。
      await _syncDesktopBall(desktop);
    } finally {
      _syncingBar = false;
    }
  }

  /// 把悬浮球的落点与外观推给原生球窗口（`windows/runner/desktop_ball_window.cpp`）。
  ///
  /// 状态每秒通知一次，但内容没变时不必过通道：用签名去重（null 表示球当前
  /// 关闭、窗口不存在）。胶囊在屏上 → 贴胶囊右侧（原生读胶囊真实矩形对齐，
  /// 球高与胶囊等高、底色用胶囊底色）；否则 → 屏幕右上角（偏移来自用户拖动）。
  ///
  /// 与 [_syncDesktopBar] 同一套「挂起标记」合并：窗口事件与每秒的推送可能同时
  /// 进来，正在同步时只标记待处理，结束后补一次。
  Future<void> _syncDesktopBall(DesktopScheduleProvider desktop) async {
    if (!mounted) return;
    if (_syncingBall) {
      _ballSyncPending = true;
      return;
    }
    _syncingBall = true;
    try {
      do {
        _ballSyncPending = false;
        await _pushDesktopBall(desktop);
      } while (_ballSyncPending);
    } finally {
      _syncingBall = false;
    }
  }

  Future<void> _pushDesktopBall(DesktopScheduleProvider desktop) async {
    if (!desktop.ballEnabled) {
      if (_ballSignature == null) return;
      _ballSignature = null;
      await DesktopBallService.close();
      return;
    }

    // 主窗口就在屏幕上时球没有意义（它是「叫回窗口」的入口）：原生侧会淡出并
    // 隐藏窗口（保留窗口对象，下次需要时淡入）。
    final visible = _ballShown;
    final mode = pickDesktopBallMode(barVisible: _barVisible);
    // 球与胶囊同色：直接取胶囊常态条的底色，拼在一起才像同一个挂件。色值仍是
    // Dart 侧的 DesktopBarPalette 一份真相，原生只负责照着画。
    final color = DesktopBarPalette.barBackground.toARGB32();
    final signature = [
      mode.name,
      visible,
      desktop.scaledCapsuleHeight,
      desktop.ballOffsetX,
      desktop.ballOffsetY,
      desktop.layer.name,
      desktop.opacity,
      color,
    ].join('|');
    if (signature == _ballSignature) return;
    _ballSignature = signature;

    await DesktopBallService.configure(
      mode: mode,
      enabled: true,
      visible: visible,
      capsuleHeight: desktop.scaledCapsuleHeight,
      gap: DesktopBarMetrics.ballGap,
      margin: desktop.ballMargin,
      offsetX: desktop.ballOffsetX,
      offsetY: desktop.ballOffsetY,
      layer: desktop.layer,
      opacity: desktop.opacity,
      color: color,
    );
  }

  /// 主窗口是否正显示在屏幕上（未最小化、未收进托盘）。
  ///
  /// 探测主窗口是否在屏上，刷新 [_ballShown]（球的显隐 + 胶囊的让位共用）。
  Future<void> _refreshBallOnScreen() async {
    final shown = shouldShowDesktopBall(
      ballEnabled: true,
      onScreen: await _readAppOnScreen(),
    );
    _ballShown = shown;
    if (_loggedBallVisible == shown) return;
    _loggedBallVisible = shown;
    await DesktopBarLog.write(
      DesktopWindowService.mainTag,
      shown ? '悬浮球：主窗口已收进托盘 / 最小化，淡入显示' : '悬浮球：主窗口在屏上，淡出隐藏',
    );
  }

  /// 查询失败（通道未就绪等）时沿用上次值：宁可保持现状，也不要因为一次失败的
  /// 探测把球凭空收起或放出。
  Future<bool> _readAppOnScreen() async {
    try {
      final probed = appWindowOnScreen(
        visible: await windowManager.isVisible(),
        minimized: await windowManager.isMinimized(),
      );
      if (probed) _appOnScreenSeen = true;
      _appOnScreen = _appOnScreenSeen ? probed : true;
    } catch (error) {
      if (!_loggedOnScreenFailure) {
        _loggedOnScreenFailure = true;
        await DesktopBarLog.write(
          DesktopWindowService.mainTag,
          '查询主窗口显隐失败（沿用上次值=$_appOnScreen）：$error',
        );
      }
    }
    return _appOnScreen;
  }

  /// 窗口事件驱动的即时同步（每秒的状态推送只作兜底）。
  ///
  /// 走整条 [_syncDesktopBar]：球的显隐一变，胶囊的让位（是否居中）也要跟着
  /// 变，两者必须同拍下发。
  void _syncBallNow() {
    if (_desktop == null) return;
    unawaited(_syncDesktopBar());
  }

  @override
  void onWindowMinimize() => _syncBallNow();

  @override
  void onWindowRestore() => _syncBallNow();

  @override
  void onWindowEvent(String eventName) {
    // 只有影响「窗口是否在屏上」的事件需要同步；move / resize 之类的高频事件
    // 交给每秒的推送兜底，不在这里反复查窗口状态。
    if (eventName == 'show' || eventName == 'hide') _syncBallNow();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _auth?.removeListener(_syncSchedulesToDesktop);
    _desktop?.removeListener(_syncDesktopBar);
    context.read<PersonalizationProvider>().removeListener(_syncTrayIcon);
    // 主窗口退出时一并关掉浮窗与悬浮球，避免留下没有数据来源的孤窗
    DesktopWindowService.closeBar();
    unawaited(DesktopBallService.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final personalization = context.watch<PersonalizationProvider>();

    // 启动加载 → 设置 PIN → 主页之间淡入淡出（整屏切换，用较慢的时长）
    final Widget page;
    final String stage;
    if (!auth.isInitialized || !personalization.isInitialized) {
      page = const Scaffold(body: Center(child: CircularProgressIndicator()));
      stage = 'loading';
    } else if (!auth.isPinSet) {
      page = const PinSetupPage();
      stage = 'pin_setup';
    } else {
      page = const HomePage();
      stage = 'home';
    }

    return FadeThroughSwitcher(
      expand: true,
      switchKey: stage,
      duration: AppMotion.slow,
      child: page,
    );
  }
}
