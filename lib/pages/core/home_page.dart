import 'dart:async';

import 'package:flutter/material.dart';
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
    context.read<AuthProvider>().addListener(_onAuthStateChanged);
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
    context.read<AuthProvider>().removeListener(_onAuthStateChanged);
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
    final destinations = <NavigationDestination>[
      const NavigationDestination(icon: Icon(Icons.dashboard), label: '主页'),
      const NavigationDestination(icon: Icon(Icons.add_circle), label: '评分'),
      const NavigationDestination(icon: Icon(Icons.bar_chart), label: '查询'),
      if (auth.isUnlocked)
        const NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
    ];

    // 确保 selectedIndex 在有效范围内
    final effectiveIndex = _currentIndex >= destinations.length
        ? 0
        : _currentIndex;

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
      bottomNavigationBar: NavigationBar(
        selectedIndex: effectiveIndex,
        onDestinationSelected: _switchTab,
        destinations: destinations,
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
