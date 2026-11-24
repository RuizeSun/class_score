import 'dart:async';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../../models/window_close_action.dart';
import '../../providers/auth_provider.dart';
import '../../providers/personalization_provider.dart';
import '../../services/app_shell_service.dart';
import '../../services/tray_service.dart';
import '../../services/window_service.dart';
import '../score/score_input_page.dart';
import '../analysis/statistics_page.dart';
import 'home_status_bar.dart';
import 'unlock_page.dart';
import 'usb_key_page.dart';
import '../settings/settings_hub_page.dart';
import '../dashboard/dashboard_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, WindowListener {
  /// 「查询」Tab 在 [_pages] / NavigationBar destinations 中的下标。
  ///
  /// 主页仪表盘的「最近评分」卡片需要跳到查询页，显式命名避免魔法数字。
  static const int _queryTabIndex = 2;

  int _currentIndex = 0;

  late final PageController _pageController;

  /// [AuthProvider] 的引用（在 [initState] 取出，供 [dispose] 使用）。
  late final AuthProvider _auth;

  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      // 点击「最近评分」时切到「查询」Tab：查询页本身是底部导航的 Tab
      // （Scaffold 无 AppBar / 返回按钮），不能再被 push 成整屏路由。
      DashboardPage(onOpenQueryTab: () => _switchTab(_queryTabIndex)),
      const ScoreInputPage(),
      const StatisticsAnalysisPage(),
      const SettingsHubPage(),
    ];
    _pageController = PageController(initialPage: _currentIndex);

    // Disable maximize button since window size is fixed
    WindowService.applyFixedSize();

    // Listen to auth state changes to toggle prevent close
    _updatePreventClose();
    // 记下引用：dispose() 里不能再 context.read（那时元素已失活，读取祖先
    // 会抛 "Looking up a deactivated widget's ancestor is unsafe"）。主窗口
    // 平时不会 dispose，但测试与将来「重新挂载主页」都会走到。
    _auth = context.read<AuthProvider>();
    _auth.addListener(_onAuthStateChanged);
    windowManager.addListener(this);
  }

  void _onAuthStateChanged() {
    _updatePreventClose();
  }

  /// 关闭动作统一在 [onWindowClose] 里分流（锁定提示 / 收进托盘 / 真正退出），
  /// 因此这里始终拦截原生的关闭消息，由 Dart 决定走哪条路。
  void _updatePreventClose() {
    windowManager.setPreventClose(true);
  }

  @override
  void onWindowClose() {
    final auth = context.read<AuthProvider>();
    final personalization = context.read<PersonalizationProvider>();
    switch (pickWindowCloseAction(
      locked: !auth.isUnlocked,
      allowCloseWhenLocked: personalization.allowCloseWhenLocked,
      closeToTray: personalization.closeToTray,
    )) {
      case WindowCloseAction.blocked:
        // 锁定态下不允许关闭：只提示，窗口原样保留。
        _showLockMessage();
        return;
      case WindowCloseAction.hideToTray:
        // 收进托盘：窗口只是隐藏，程序继续在后台跑——桌面课表胶囊与悬浮球
        // 都保持显示；真正退出走托盘 / 悬浮球菜单里的「退出程序」。
        unawaited(AppShellService.hideMainWindow());
        unawaited(TrayService.showFirstCloseHint());
        return;
      case WindowCloseAction.quit:
        // 允许真正退出：主窗口退出前把桌面上的子窗口一起关掉，否则会留下一个
        // 再也收不到状态的「孤条 / 孤球」停在桌面上。
        unawaited(AppShellService.quitApplication());
        return;
    }
  }

  @override
  void onWindowMinimize() {
    final auth = context.read<AuthProvider>();
    final personalization = context.read<PersonalizationProvider>();
    if (!auth.isUnlocked && !personalization.allowMinimizeWhenLocked) {
      // Show lock message and restore window only if minimize is not allowed
      _showLockMessage();
      windowManager.show();
    }
    // If unlocked or minimize allowed when locked, allow minimize
  }

  void _showLockMessage() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.lock_outline, color: Colors.white),
            SizedBox(width: 12),
            Text('需要先解锁才能操作程序'),
          ],
        ),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthStateChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _switchTab(int newIndex) {
    if (newIndex == _currentIndex) return;
    _pageController.animateToPage(
      newIndex,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    setState(() {
      _currentIndex = newIndex;
    });
  }

  Future<void> _showUnlockPage() async {
    await showUnlockOverlay(context);
  }

  void _showUsbKeyPage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const UsbKeyPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final glassQuality = context.watch<PersonalizationProvider>().glassQuality;
    final currentCourse = auth.currentCourseName;

    // 如果未解锁且当前在设置tab，自动跳转到主页
    if (!auth.isUnlocked && _currentIndex >= 3) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _currentIndex >= 3) {
          _switchTab(0);
        }
      });
    }

    // 动态构建导航栏：未解锁时不显示设置tab
    final selectedTabColor = Theme.of(context).colorScheme.primary;
    final tabs = <GlassTab>[
      const GlassTab(icon: Icon(Icons.dashboard), label: '主页'),
      const GlassTab(icon: Icon(Icons.add_circle), label: '评分'),
      const GlassTab(icon: Icon(Icons.bar_chart), label: '查询'),
      if (auth.isUnlocked)
        const GlassTab(icon: Icon(Icons.settings), label: '设置'),
    ];

    // 确保 selectedIndex 在有效范围内
    final effectiveIndex = _currentIndex >= tabs.length ? 0 : _currentIndex;

    return Scaffold(
      body: Column(
        children: [
          // Combined status bar — 胶囊样式
          HomeStatusBar(
            isUnlocked: auth.isUnlocked,
            currentCourseName: currentCourse,
            onUnlock: _showUnlockPage,
            onShowUsbKey: _showUsbKeyPage,
            onLock: () => auth.lock(),
          ),
          // Page content with PageView
          Expanded(child: _buildPageContent()),
        ],
      ),
      bottomNavigationBar: SizedBox(
        height: 96,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 16),
            child: SizedBox(
              width: tabs.length * 120.0,
              child: GlassTabBar.bottom(
                tabs: tabs,
                selectedIndex: effectiveIndex,
                onTabSelected: _switchTab,
                quality: glassQuality,
                backgroundQuality: glassQuality,
                horizontalPadding: 16,
                verticalPadding: 12,
                barHeight: 64,
                tabPadding: const EdgeInsets.symmetric(horizontal: 8),
                // 指示块（选中 Tab 下那颗白胶囊）按下 / 拖动时向外鼓起的幅度。
                //
                // 这个值调过两次，别再来回摆：
                // - 4/4（原始）：指示块只比轨道圆角多鼓 4pt，肉眼看不出浮起；
                // - 14/11（上一版）：**过了**——用户反馈「浮动幅度又太大了」，
                //   指示块像一个白盘子呼在轨道上，压住了相邻 Tab 的图标。
                // 现在取 8/5：垂直多盖 8pt（相对 64 高的轨道约 +12%），
                // 已经明显浮出轮廓，又不会盖到上一行/相邻图标。
                // 上限仍是 16（轨道 64 + 上下 padding 12 的整条 bar 居中放在
                // 96 高的 bottomNavigationBar 里：(96-88)/2 + 12 = 16）。
                indicatorExpansion: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 8,
                ),
                // 底部导航条压在纯色页面上：这里的背景模糊（blur）与片元
                // 着色器（thickness / 色散 / 边缘高光）在纯色底上画不出可辨
                // 差异，但它是全应用最贵的一个玻璃面——每条 Tab 切换都要重画
                // 轨道 + 指示块两层，且每层各推一次全窗口 BackdropFilter。
                // 保留玻璃的透明底色与高光，只把 blur 归零。
                settings: LiquidGlassSettings(
                  glassColor: Colors.grey.shade400.withValues(alpha: 0.20),
                  thickness: 22,
                  blur: 0,
                  chromaticAberration: 0.05,
                  rimShade: 0.6,
                  rimLight: 1.0,
                  glowIntensity: 0.8,
                ),
                indicatorColor: Colors.white.withValues(alpha: 0.10),
                // 指示块（选中 Tab 下的那颗白色胶囊）同理：它每秒都跟着
                // 弹簧动画移动，模糊层一开，移动期间每帧都要重新采样整窗背景。
                indicatorSettings: LiquidGlassSettings(
                  glassColor: Colors.white.withValues(alpha: 0.12),
                  thickness: 12,
                  blur: 0,
                  chromaticAberration: 0.08,
                  rimShade: 0.7,
                  edgeAbsorption: 0.3,
                  bodyShade: 0.1,
                  rimLight: 0.8,
                  glowIntensity: 0.3,
                  shadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 6,
                      spreadRadius: 0,
                    ),
                  ],
                ),
                indicatorBorderRadius: 9999,
                glowOpacity: 0,
                magnification: 1.0,
                maskingQuality: glassQuality == GlassQuality.minimal
                    ? MaskingQuality.off
                    : MaskingQuality.high,
                selectedIconColor: selectedTabColor,
                selectedLabelColor: selectedTabColor,
                unselectedIconColor: Colors.black87,
                unselectedLabelColor: Colors.black87,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageContent() {
    return PageView(
      controller: _pageController,
      physics: const NeverScrollableScrollPhysics(),
      children: _pages,
    );
  }
}
