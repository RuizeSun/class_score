import 'dart:async';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:window_manager/window_manager.dart';
import 'database/database_helper.dart';
import 'models/desktop_ball_style.dart';
import 'pages/desktop_bar/desktop_bar_window.dart';
import 'services/app_shell_service.dart';
import 'services/desktop_ball_service.dart';
import 'services/desktop_bar_log.dart';
import 'services/desktop_window_service.dart';
import 'services/tray_service.dart';
import 'services/update_service.dart';
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
import 'pages/settings/update_dialog.dart';
import 'widgets/motion.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面课表浮窗是 desktop_multi_window 创建的第二个引擎，需要走完全不同的
  // 启动路径（不初始化主窗口、不读数据库，只渲染主窗口推过来的状态）。
  if (await _isDesktopBarEngine(args)) {
    await DesktopBarLog.write(DesktopWindowService.barTag, '浮窗引擎启动，入口参数=$args');
    runApp(DesktopBarWindow(launchArguments: args));
    return;
  }

  await DesktopBarLog.write(DesktopWindowService.mainTag, '主窗口启动，入口参数=$args');
  // Windows 上首次加载 sqlite3.dll 会同步卡住主 isolate，提前到首帧之前做，
  // 这样转圈动画开始后就不会再被数据库初始化打断。
  DatabaseHelper.initializeFfi();
  await WindowService.setup();
  runApp(
    LiquidGlassWidgets.wrap(
      child: const MyApp(),
      brightnessResolver: Theme.maybeBrightnessOf,
    ),
  );
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

    return GlassTheme(
      data: GlassThemeData(
        light: GlassThemeVariant(quality: personalization.glassQuality),
        dark: GlassThemeVariant(quality: personalization.glassQuality),
      ),
      child: MaterialApp(
        title: '班级量化评分管理',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: personalization.seedColor,
          ),
          useMaterial3: true,
        ),
        home: const AppEntry(),
      ),
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

  /// 数据就绪标记：加载页只等 Provider 把设置读完。
  ///
  /// shader 预热与原生接线都放到离开加载页之后，避免它们占用 UI isolate
  /// 让转圈动画看起来像卡死。
  bool _dataReady = false;

  /// 启动初始化失败的原因；非 null 时渲染可读的错误页而不是一直转圈。
  String? _startupError;

  /// 防止「配置 + 推内容」在连续的 notify 下并发重入。
  bool _syncingBar = false;
  bool _barSyncPending = false;

  /// 下一次允许尝试创建浮窗的时间（失败退避，避免每秒重试刷屏）。
  DateTime _nextBarAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 浮窗「是否还存在」探测的最短间隔。
  ///
  /// `barExists()` 每次都要清掉本地缓存并向插件通道问一遍所有窗口；内容没变化时
  /// 没必要跟着每一拍推送跑，因此限频到这里。
  static const Duration _barExistenceCheckInterval = Duration(seconds: 10);

  /// 下一次允许做浮窗存在性探测的时间。
  DateTime _nextBarExistenceCheck = DateTime.fromMillisecondsSinceEpoch(0);

  /// 悬浮球显隐看门狗周期（见 [_checkBallVisibility]）。
  static const Duration _ballWatchdogInterval = Duration(seconds: 15);

  /// 球的显隐看门狗（见 [_checkBallVisibility]）。
  Timer? _ballWatchdog;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _beginStartup());
  }

  /// 从加载页进入主界面的一次启动流程（首帧后调用；失败可从错误页重试）。
  Future<void> _beginStartup() async {
    if (!mounted) return;
    // 先把 Provider 取出来：下面有 await，之后再碰 context 会触发
    // use_build_context_synchronously（而且 widget 也可能已被销毁）。
    final personalization = context.read<PersonalizationProvider>();
    final auth = context.read<AuthProvider>();
    final desktop = context.read<DesktopScheduleProvider>();

    // 互不依赖的初始化先一起启动，避免串行等待；sqflite 的查询本身在后台 isolate。
    //
    // 任何一步失败都必须落到 [_startupError]：以前这里没有任何兜底，初始化
    // 抛异常就会永远停在转圈页（看起来就是「启动卡死」）。
    final authReady = auth.init();
    final scoreReady = context.read<ScoreProvider>().init();
    final desktopReady = desktop.init();

    try {
      await personalization.init();
      if (!mounted) return;
      await Future.wait([authReady, scoreReady, desktopReady]);
      if (!mounted) return;
    } catch (error, stack) {
      debugPrint('启动初始化失败：$error\n$stack');
      if (!mounted) return;
      setState(() {
        _startupError = _describeStartupError(error);
        _dataReady = true;
      });
      return;
    }

    _desktop = desktop;
    _auth = auth;

    // 更新检查的来源偏好 / 「上次可用源」存 app_settings：接线一次即可，
    // 之后 UpdateService 自己读写（不接线则偏好只在本次运行内生效）。
    UpdateService.instance.bindSettings(
      read: (key) => DatabaseHelper.instance.getSetting(key),
      write: (key, value) => DatabaseHelper.instance.setSetting(key, value),
    );

    // 数据齐了就立刻离开加载页：其余同步接线等淡入动画跑完再做。
    setState(() => _dataReady = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        _finishStartupAfterTransition(
          personalization: personalization,
          auth: auth,
          desktop: desktop,
        ),
      );
    });
  }

  /// 错误页上的「重试」：把状态复位后再跑一次同一条启动流程。
  void _retryStartup() {
    setState(() {
      _startupError = null;
      _dataReady = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _beginStartup());
  }

  /// 把启动异常翻译成用户看得懂的一句话 + 处理建议。
  static String _describeStartupError(Object error) {
    final db = DatabaseHelper.instance;
    final dbError = db.lastOpenError;
    final dir = db.dbDir;
    final nl = String.fromCharCodes(const [10, 10]);
    if (dbError != null && dbError.isNotEmpty) {
      return '读取本地数据库失败。$nl$dbError$nl数据目录：$dir';
    }
    return '启动时发生错误。$nl$error$nl数据目录：$dir';
  }

  /// 主页淡入完成后再接托盘 / 浮窗 / shader，避免打断转圈与切页动画。
  Future<void> _finishStartupAfterTransition({
    required PersonalizationProvider personalization,
    required AuthProvider auth,
    required DesktopScheduleProvider desktop,
  }) async {
    await Future<void>.delayed(
      AppMotion.slow + const Duration(milliseconds: 120),
    );
    if (!mounted) return;

    // 首帧后按真实非客户区再校准一次窗口尺寸，确保内容区为 1280x800。
    unawaited(WindowService.refresh());

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

    // 桌面课表：课表数据来自 AuthProvider，状态机与配置在 DesktopScheduleProvider，
    // 这里只做两者的接线与「把状态推给浮窗」。
    auth.addListener(_syncSchedulesToDesktop);
    desktop.addListener(_syncDesktopBar);
    _syncTrayIcon();
    _syncSchedulesToDesktop();

    // 浮窗创建要跨引擎，可能耗时较久；它不阻塞加载页切到主界面。
    unawaited(_syncDesktopBar());

    // 兜底复查：窗口事件是主路径，但万一漏了事件（或被外部改状态），球不该一直
    // 停在错误状态上。低频定时器只查窗口显隐，翻转了才走整条同步。
    _ballWatchdog?.cancel();
    _ballWatchdog = Timer.periodic(
      _ballWatchdogInterval,
      (_) => unawaited(_checkBallVisibility()),
    );

    unawaited(_warmGlassAfterFirstFrame());

    // 自动更新：首页稳定后静默检查 GitHub Releases；有新版本才弹窗，失败不打扰。
    unawaited(_autoCheckForUpdate());
  }

  /// 启动后的静默更新检查。
  ///
  /// 延迟几秒等界面与托盘 / 浮窗接线都安定下来；只在发现新版本时弹一次
  /// 更新弹窗，检查失败或已是最新都保持安静（手动检查入口在系统设置）。
  Future<void> _autoCheckForUpdate() async {
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!mounted) return;
    try {
      final update = await UpdateService.instance.checkForUpdate();
      if (!mounted || !update.updateAvailable) return;
      await showUpdateAvailableDialog(context, update);
    } catch (_) {
      // 静默：自动检查失败不打扰用户
    }
  }

  /// 主页首帧之后再预热玻璃 shader。
  ///
  /// 预热必须在 UI isolate 编译 shader，放在转圈阶段会让转圈看起来冻结；
  /// 放到这里即使有短暂掉帧，用户也已经看到界面，不会被误认为卡死。
  Future<void> _warmGlassAfterFirstFrame() async {
    if (!mounted) return;
    if (context.read<PersonalizationProvider>().glassQuality ==
        GlassQuality.minimal) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    await LiquidGlassWidgets.initialize();
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
    _desktop?.updateSchedules(auth.courseSchedules, auth.scheduleAdjustments);
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
          // 重新开启时立刻尝试创建与探测，不用等退避 / 限频
          _nextBarAttempt = DateTime.fromMillisecondsSinceEpoch(0);
          _nextBarExistenceCheck = DateTime.fromMillisecondsSinceEpoch(0);
          continue;
        }

        // 浮窗可能被外部关掉（任务管理器 / 系统回收），此时要重新创建，否则会出现
        // 「设置里显示已开启、桌面上却没有条」。探测限频到 [_barExistenceCheckInterval]。
        final now = DateTime.now();
        if (_barVisible && !now.isBefore(_nextBarExistenceCheck)) {
          _nextBarExistenceCheck = now.add(_barExistenceCheckInterval);
          if (!await DesktopWindowService.barExists()) {
            _barVisible = false;
          }
        }

        if (!_barVisible) {
          // 创建失败后退避重试：不退避就会反复重试 + 刷屏。
          if (now.isBefore(_nextBarAttempt)) continue;
          _nextBarAttempt = now.add(DesktopWindowService.retryBackoff);
          await DesktopWindowService.logWindowList();
          _barVisible = await DesktopWindowService.showBar();
          if (_barVisible) {
            _nextBarExistenceCheck = now.add(_barExistenceCheckInterval);
          }
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

  /// 窗口事件驱动的即时同步（低频的看门狗只作兜底）。
  ///
  /// 走整条 [_syncDesktopBar]：球的显隐一变，胶囊的让位（是否居中）也要跟着
  /// 变，两者必须同拍下发。
  void _syncBallNow() {
    if (_desktop == null) return;
    unawaited(_syncDesktopBar());
  }

  /// 球显隐的兜底复查（见 [_ballWatchdogInterval]）。
  ///
  /// 只有「球的显隐真的翻转」时才触发整条同步——整条同步包含查窗口、探浮窗、
  /// 跨引擎推内容，不该为了一次复查白跑。
  Future<void> _checkBallVisibility() async {
    if (!mounted) return;
    final desktop = _desktop;
    if (desktop == null || !desktop.ballEnabled) return;
    final before = _ballShown;
    await _refreshBallOnScreen();
    if (before == _ballShown) return;
    await _syncDesktopBar();
  }

  @override
  void onWindowMinimize() => _syncBallNow();

  @override
  void onWindowRestore() => _syncBallNow();

  @override
  void onWindowEvent(String eventName) {
    // 只有影响「窗口是否在屏上」的事件需要同步；move / resize 之类的高频事件
    // 交给低频的球显隐看门狗兜底，不在这里反复查窗口状态。
    if (eventName == 'show' || eventName == 'hide') _syncBallNow();
  }

  @override
  void dispose() {
    _ballWatchdog?.cancel();
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
    if (_startupError != null) {
      page = _StartupErrorPage(
        message: _startupError!,
        // 重试走整页重建：Provider 的 init 都是幂等的，失败的那一步会再跑一次。
        onRetry: _retryStartup,
      );
      stage = 'startup_error';
    } else if (!auth.isInitialized ||
        !personalization.isInitialized ||
        !_dataReady) {
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

/// 启动失败时的兜底页：说清原因、给出数据目录与「重试」，绝不让人对着转圈猜。
///
/// 以前启动路径上任何一次异常（数据库打不开、迁移失败、设置项异常）都会让
/// 界面永远停在 CircularProgressIndicator 上，看起来和「闪退 / 卡死」一样。
class _StartupErrorPage extends StatelessWidget {
  const _StartupErrorPage({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 56,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text('启动没有完成', style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                SelectableText(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
