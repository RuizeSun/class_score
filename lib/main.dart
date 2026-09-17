import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/window_service.dart';
import 'providers/group_provider.dart';
import 'providers/student_provider.dart';
import 'providers/score_provider.dart';
import 'providers/score_item_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/personalization_provider.dart';
import 'pages/core/home_page.dart';
import 'pages/core/pin_setup_page.dart';
import 'widgets/motion.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WindowService.setup();
  runApp(const MyApp());
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

class _AppEntryState extends State<AppEntry> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      context.read<PersonalizationProvider>().init();
      context.read<AuthProvider>().init();
      context.read<ScoreProvider>().init();
      // 首帧后按真实非客户区再校准一次窗口尺寸，确保内容区为 1280x800。
      await WindowService.refresh();
    });
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
