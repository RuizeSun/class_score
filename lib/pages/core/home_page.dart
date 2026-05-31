import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../score/score_input_page.dart';
import '../score/score_records_page.dart';
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
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  int? _previousIndex;

  late final AnimationController _slideController;

  final List<Widget> _pages = [
    const DashboardPage(),
    const ScoreInputPage(),
    const ScoreRecordsPage(),
    const StatisticsAnalysisPage(),
    const SettingsHubPage(),
  ];

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  void _switchTab(int newIndex) {
    if (newIndex == _currentIndex) return;
    setState(() {
      _previousIndex = _currentIndex;
      _currentIndex = newIndex;
    });
    _slideController.forward(from: 0.0).then((_) {
      if (mounted) setState(() => _previousIndex = null);
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

    return Scaffold(
      body: Column(
        children: [
          // Combined status bar
          Container(
            width: double.infinity,
            height: 40,
            color: auth.isUnlocked ? Colors.green.shade50 : Colors.red.shade50,
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
                      Icon(Icons.school, size: 16, color: Colors.blue.shade700),
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
                      shape: const RoundedRectangleBorder(),
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
                      shape: const RoundedRectangleBorder(),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => auth.lock(),
                    icon: const Icon(Icons.lock, size: 14),
                    label: const Text('上锁', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orange,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: const RoundedRectangleBorder(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Page content with slide animation
          Expanded(child: _buildPageContent()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _switchTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard), label: '主页'),
          NavigationDestination(icon: Icon(Icons.add_circle), label: '评分'),
          NavigationDestination(icon: Icon(Icons.history), label: '记录'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: '统计分析'),
          NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }

  Widget _buildPageContent() {
    final isForward = _previousIndex != null && _currentIndex > _previousIndex!;
    final isAnimating = _previousIndex != null;

    return Stack(
      children: [
        // Previous page (slides out)
        if (isAnimating)
          AnimatedBuilder(
            animation: _slideController,
            builder: (context, child) {
              final offset =
                  Tween<Offset>(
                        begin: Offset.zero,
                        end: Offset(isForward ? -1.0 : 1.0, 0),
                      )
                      .animate(
                        CurvedAnimation(
                          parent: _slideController,
                          curve: Curves.easeInOut,
                        ),
                      )
                      .value;
              return Transform.translate(
                offset: Offset(
                  offset.dx * MediaQuery.of(context).size.width,
                  0,
                ),
                child: child,
              );
            },
            child: _pages[_previousIndex!],
          ),
        // Current page (slides in)
        AnimatedBuilder(
          animation: _slideController,
          builder: (context, child) {
            final offset = isAnimating
                ? Tween<Offset>(
                        begin: Offset(isForward ? 1.0 : -1.0, 0),
                        end: Offset.zero,
                      )
                      .animate(
                        CurvedAnimation(
                          parent: _slideController,
                          curve: Curves.easeInOut,
                        ),
                      )
                      .value
                : Offset.zero;
            return Transform.translate(
              offset: Offset(offset.dx * MediaQuery.of(context).size.width, 0),
              child: child,
            );
          },
          child: _pages[_currentIndex],
        ),
      ],
    );
  }
}
