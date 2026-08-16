import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../../providers/auth_provider.dart';
import '../../providers/personalization_provider.dart';
import '../score/score_input_page.dart';
import '../analysis/statistics_page.dart';
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
  int _currentIndex = 0;

  late final PageController _pageController;

  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      const DashboardPage(),
      const ScoreInputPage(),
      const StatisticsAnalysisPage(),
      const SettingsHubPage(),
    ];
    _pageController = PageController(initialPage: _currentIndex);

    // Disable maximize button since window size is fixed
    windowManager.setMaximumSize(const Size(1200, 800));
    windowManager.setMinimumSize(const Size(1200, 800));

    // Listen to auth state changes to toggle prevent close
    _updatePreventClose();
    context.read<AuthProvider>().addListener(_onAuthStateChanged);
    windowManager.addListener(this);
  }

  void _onAuthStateChanged() {
    _updatePreventClose();
  }

  void _updatePreventClose() {
    final auth = context.read<AuthProvider>();
    final personalization = context.read<PersonalizationProvider>();
    final shouldPreventClose =
        !auth.isUnlocked && !personalization.allowCloseWhenLocked;
    windowManager.setPreventClose(shouldPreventClose);
  }

  @override
  void onWindowClose() {
    final auth = context.read<AuthProvider>();
    final personalization = context.read<PersonalizationProvider>();
    if (!auth.isUnlocked && !personalization.allowCloseWhenLocked) {
      // Show lock message only if close is not allowed when locked
      _showLockMessage();
    }
    // If unlocked or close allowed when locked, allow close
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

  void _showUnlockPage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const UnlockPage()),
    );
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Container(
              width: double.infinity,
              height: 40,
              decoration: BoxDecoration(
                color: auth.isUnlocked
                    ? Colors.green.shade50
                    : Colors.red.shade50,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Row(
                      children: [
                        Icon(
                          auth.isUnlocked ? Icons.lock_open : Icons.lock,
                          size: 16,
                          color: auth.isUnlocked ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          auth.isUnlocked ? '已解锁' : '已锁定',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: auth.isUnlocked ? Colors.green : Colors.red,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Center(
                          child: Container(
                            width: 1,
                            height: 16,
                            color: Colors.grey.withOpacity(0.3),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          Icons.school,
                          size: 16,
                          color: Colors.blue.shade700,
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '课程：${currentCourse ?? '无'}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.blue.shade700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (!auth.isUnlocked)
                    TextButton.icon(
                      onPressed: _showUnlockPage,
                      icon: const Icon(Icons.lock_open, size: 14),
                      label: const Text('解锁', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    )
                  else ...[
                    TextButton.icon(
                      onPressed: _showUsbKeyPage,
                      icon: const Icon(Icons.usb, size: 14),
                      label: const Text('密钥', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.indigo,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => auth.lock(),
                      icon: const Icon(Icons.lock, size: 14),
                      label: const Text('上锁', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.orange,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
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
