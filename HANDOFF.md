# HANDOFF — class_score

## 元信息

- 生成时间：2026-09-26（2026-09-27 更新悬浮球显隐 / 让位、倒计时与提醒语显示时间、查询页联动提示）
- commit：本地已提交「倒计时 / 提醒语显示时间拆分」（尚未 push）；历史：9924377 docs、3305436 悬浮球显隐、2a9e75c = build: 1.5.0
- 分支：main
- last_verified_commit：工作区（`fvm flutter test` 147 全过、`fvm flutter analyze` 48 条既有 info、无新增）；上一次已验证提交 3305436（143 全过、analyze 无新增、`fvm flutter build windows --release` 通过；运行时实测：球隐藏时胶囊 left=920（2560 宽屏精确居中）、球显示时 888，位移是 140/220ms 缓动滑动）
- 仅支持 Windows（用户明确；android/ios/macos/linux/web 目录为脚手架残留）

## 项目一句话

Flutter (Windows) 班级量化评分桌面应用：学生/分组/评分项/评分记录 SQLite 本地存储，PIN+USB 解锁，统计图表，外加桌面课表胶囊、悬浮球、托盘等多窗口原生功能。

## 目录地图

- lib/main.dart — 入口、Provider 注册、托盘/浮窗/悬浮球接线
- lib/pages/ — 页面：core(首页/解锁/PIN) dashboard score analysis settings student desktop_bar
- lib/providers/ — 7 个 ChangeNotifier（auth/group/student/score/score_item/personalization/desktop_schedule）
- lib/database/database_helper.dart — SQLite 单例（表结构、迁移、app_settings）
- lib/models/ — 数据模型（手写 toMap/fromMap）
- lib/services/ — 窗口/托盘/天气/备份/导入等服务
- lib/widgets/ — 通用组件，含 desktop_schedule/ 浮窗 UI
- windows/runner/ — 原生 C++（desktop_bar_channel.cpp、desktop_ball_window.cpp、tray_icon.cpp、app_quit.cpp）
- test/ — 146 个测试；.github/workflows/flutter.yml — CI

## 核心链路

1. 启动：main.dart:27 main → main.dart:32 判定是否浮窗引擎（是则只跑 DesktopBarWindow，不读数据库）→ main.dart:45 WindowService.setup → main.dart:46 runApp。
2. 主体：main.dart:115 MaterialApp（主题 main.dart:119 取 PersonalizationProvider.seedColor）→ main.dart:122 AppEntry → main.dart:467 未设 PIN 走 PinSetupPage，否则 HomePage。
3. 初始化：main.dart:189-230（post-frame）各 provider.init + 托盘/悬浮球/课表浮窗接线；悬浮球显隐由 main.dart:382 _refreshBallOnScreen 判定、main.dart:336 _pushDesktopBall 推送。
4. 页面：home_page.dart:43 4 个 Tab（Dashboard/评分/统计与查询/设置），home_page.dart:201 NavigationBar + home_page.dart:210 PageView 切换；设置子页在 settings_hub_page.dart:100 setState(\_current) 就地切换（:195-234 返回各子视图）。
5. 数据：DatabaseHelper.instance（database_helper.dart:5）→ 数据库在 exe 同级 data/score.db（:11-17），版本 10（:35），设置存 app_settings 表（:292 getSetting）。
6. 浮窗：DesktopScheduleProvider 状态 → main.dart:261 pushBarPayload → windows/runner/desktop_bar_channel.cpp 原生绘制/裁剪。

## 关键依赖 / 状态管理 / 网络

- 状态管理：provider（main.dart:86 MultiProvider，7 个 ChangeNotifier）。
- 数据库：sqflite_common_ffi（database_helper.dart:32），非移动端 sqflite。
- UI/数据：fl_chart、csv、excel、file_picker；窗口：window_manager、desktop_multi_window、win32、screen_retriever；杂项：package_info_plus、path_provider。
- 网络：仅天气 — lib/services/weather_service.dart:33 Open-Meteo、:50 地理编码、:123 HttpClient，免 API Key，失败回退缓存。其余功能全部本地。
- 持久化：无 SharedPreferences，全部走 SQLite（库 + app_settings 表）。

## 任务导航

- 加页面（底部 Tab）：lib/pages/ 新建 → home_page.dart:43 \_pages 与 destinations 各加一项；Tab 间跳转仿 home_page.dart:46 onOpenQueryTab。
- 加设置子页：lib/pages/settings/ 新建 View → settings_hub_page.dart 的 section 枚举 + :195-234 返回值 + :108 ListView 入口。
- 二级整屏页：Navigator.push，参考 analysis/statistics_page.dart:38（注意 dashboard_page.dart:17 注释：Tab 内页面不可 push）。
- 查询页（统计报表 ↔ 记录管理）联动：左栏点行 → 右栏 `externalFilter`（`_syncExternalFilter`）设本栏筛选；提示胶囊 ✕ 走 `onClearExternalFilter`（清筛选回全部）。本栏手动改下拉经 `_releaseLinkedFilterIfChanged`（statistics_page.dart:405）判定已非联动目标后只撤提示/高亮、留新筛选；`didUpdateWidget`（:378）为此特判提前 return，勿再无脑同步。
- 改状态：改/加 lib/providers/\*\_provider.dart；新 Provider 需在 main.dart:86 注册；持久化经 DatabaseHelper。
- 调 API：现有仅 weather_service.dart；新 HTTP 一律放 lib/services/，用 dart:io HttpClient（仓库无 dio/http 包）。
- 改模型：lib/models/\*.dart（toMap/fromMap 手写，见 student.dart:18/28）+ database_helper.dart:43 \_onCreate 并在 \_onUpgrade 加迁移、version 递增（当前 10）。
- 加依赖：pubspec.yaml → fvm flutter pub get。
- 改主题：personalization_provider.dart:97 setSeedColor（存 app_settings 十六进制串，读取 :52 用 radix 16）+ main.dart:117-119；选择 UI 在 pages/settings/personalization_view.dart。
- 平台权限/原生：windows/runner/（runner.exe.manifest、CMakeLists.txt、\*.cpp 通道），Dart 侧通道常量在 services/desktop_window_service.dart:18、desktop_ball_service.dart、tray_service.dart。
- 悬浮球显隐 / 让位：球只是「叫回主窗口」的入口，**主窗口在屏上（isVisible && !isMinimized）就不显示**——判定在 main.dart:382 `_refreshBallOnScreen`（windowManager.isVisible/isMinimized，窗口事件 `onWindowMinimize/onWindowRestore/onWindowEvent('show'/'hide')` 即时触发，每秒推送只兜底），显隐经 `desktop_ball_service.dart` 的 `configure(visible:)` 推给原生；原生淡出/淡入 + 隐藏见 desktop_ball_window.cpp 的 `ApplyVisibility`/`StepFade`/`Paint`（fade 走 `SourceConstantAlpha`，淡出中 `WM_NCHITTEST` 不接点击，窗口只隐藏不销毁）。**胶囊的让位必须跟着球的显隐走**：`desktop_schedule_common.dart` 的 `desktopBallReserve(ballEnabled:, ballVisible:)`（球藏着 → 归零 → 胶囊回正）→ provider `toBarPayload(ballVisible:)` → desktop_bar_channel.cpp 的 reserve 计算 + `StartXSlide`（只改了 x 才滑动 0.14/0.22s，其余改动瞬时）。
- 倒计时 / 提醒语显示时间：设置页 desktop_schedule_settings.dart 两个 NumberChoiceTile（0 = 不显示）→ provider `countdownSeconds`/`hintSeconds`（key `desktop_schedule_countdown_seconds`/`_hint_seconds`；旧 `desktop_schedule_alternate_seconds` 只在尚未写过新键时回退）→ models/desktop_schedule_state.dart 纯函数 `desktopCountdownView()` 按 `now − phaseStart` 求 图三 / 图四 / 都不显示 → provider `countdownView` → payload `countdown_view` → DesktopScheduleWidget.countdownView。
- 退出程序：原生 app_quit.cpp QuitApplicationNow()（RemoveTrayIcon → TerminateProcess）；托盘 / 悬浮球菜单直接调用它，Dart 侧走 tray_service.dart quitNow()（「关闭窗口即退出」经 app_shell_service.dart quitApplication）。**不要**改回 `window_manager.destroy()` 或 `ExitProcess`：前者只是 PostQuitMessage、后者会跑 DLL detach 收尾子引擎，都要 3~5 秒（实测 5.8s vs 0.14s）。
- 打包：本地 `fvm flutter build windows --release`；CI：commit message 以 `build: <版本号>` 开头推 main → flutter.yml:12 触发、:31 构建、:38 取版本、:70 打 tag 并发布 Release zip。用户没有要求的情况下严禁私自发布。
