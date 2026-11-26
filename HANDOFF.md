# HANDOFF — class_score

## 元信息

- 生成时间：2026-09-26（2026-09-30：P0 性能修复）
- commit：1.6.2 = 本地待发（多源更新 + Gitee 镜像）；1.6.1 = 942c675（已 push、已发版）；
  1.5.1 = 04e18ba
- last_verified：2026-11-26 1.6.2 筹备中（`fvm flutter test` 236 全过、
  `fvm flutter analyze` 62 条既有 info / warning、无 error；`build windows --release` 通过）。
  本轮内容：检查更新改为 Gitee/GitHub 多源回退（失败不再统一提示网络错误），
  CI 发版后镜像到 Gitee 并写 `update` 分支 latest.json；Gitee 侧需先建仓库与
  secrets（见「关键依赖 / 网络」）。
  上一轮 2026-11-26 1.6.1（tag 942c675，assets release.zip + release.zip.sha256
  均上传，CI 构建全绿；低配机第二轮帧率优化，`fvm flutter test` 224 全过、
  63 条既有 info / warning、无 error；`build windows --release` 通过）；
  更早 2026-11-23 1.5.4（`fvm flutter test` 210 全过、
  `fvm flutter analyze` 43 条既有 info、无新增；`fvm flutter build windows --release` 通过；
  驱动器枚举已用「新旧实现结果逐一对齐」的临时测试验证等价）
- Flutter SDK：**fvm 3.47.9**（见下方「稳定性和数据安全红线」）
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
- lib/widgets/ — 通用组件 + desktop_schedule/ 浮窗 UI
- windows/runner/ — 原生 C++（desktop_bar_channel.cpp、desktop_ball_window.cpp、tray_icon.cpp、app_quit.cpp）
- test/ — 224 个测试（含 backup_service / database_recovery / database_helper 的 DB 用例，用 DatabaseHelper.dbDirOverride 指到临时目录）；.github/workflows/flutter.yml — CI（Flutter 版本已钉死 3.47.9）

## 核心链路

1. 启动：main.dart main() → 判定是否浮窗引擎（是则只跑 DesktopBarWindow，不读数据库）→ WindowService.setup → runApp。
2. 主体：MaterialApp（主题取 PersonalizationProvider.seedColor）→ AppEntry → 未设 PIN 走 PinSetupPage，否则 HomePage。
3. 初始化：AppEntry 的 post-frame：各 provider.init + 托盘 / 悬浮球 / 课表浮窗接线；同步与推送全在 main.dart（_syncDesktopBar / _pushDesktopBall / _refreshBallOnScreen）。
4. 页面：home_page.dart 的 _pages 4 个 Tab（Dashboard/评分/统计与查询/设置）+ NavigationBar + PageView 切换；设置子页在 settings_hub_page.dart 就地 setState 切换（返回各子视图）。
5. 数据：DatabaseHelper.instance → 数据库在 exe 同级 data/score.db，版本 10，设置存 app_settings 表。
6. 浮窗：DesktopScheduleProvider 状态 → toBarPayload → windows/runner/desktop_bar_channel.cpp 原生绘制 / 裁剪。

## 关键依赖 / 状态管理 / 网络

- 状态管理：provider（main.dart:86 MultiProvider，7 个 ChangeNotifier）。
- 数据库：sqflite_common_ffi（database_helper.dart:32），非移动端 sqflite。
- UI/数据：fl_chart、csv、excel、file_picker；窗口：window_manager、desktop_multi_window、win32、screen_retriever；杂项：package_info_plus、path_provider。
- 网络：天气（weather_service.dart，Open-Meteo，免 API Key，失败回退缓存）+ 检查更新
  （update_service.dart，Gitee 镜像 + GitHub Releases）；其余功能全部本地。
- **检查更新必须多数据源**（2026-11-26）：`gitee.com` / `api.github.com` / `github.com`
  是三台不同服务器，校园网 / 一体机上常见「浏览器能开 github.com，api.github.com 被
  RST 秒断」。`checkForVersion` 按偏好排序逐个尝试：Gitee 清单 → GitHub REST API →
  GitHub `releases.atom`；全失败才抛 `UpdateCheckException`，并把每个源的真实原因
  （HTTP 码 / SocketException / 超时）一起带到界面。**勿**改回「异常一律吞成 null +
  统一提示网络错误」，那样线上出错无法定位。
- **客户端绝不调 Gitee API**（2026-11-26 实测）：匿名请求直接
  `403 Forbidden (Rate Limit Exceeded)`，冷置后重试仍 403。所以 Gitee 侧只提供
  - 清单：`https://gitee.com/{owner}/{repo}/raw/update/latest.json`（raw，匿名可读，
    `Cache-Control: max-age=60`，客户端加 `?_t=` 破缓存）；
  - 附件：`https://gitee.com/{owner}/{repo}/releases/download/{tag}/release.zip`
    （匿名 200，实测 50MB 附件直下没问题）。
  注意 Gitee **没有** GitHub 那种 `releases/latest/download/...` 滚动路径（实测 404），
  所以清单里必须写死带 tag 的绝对 URL。
- **更新源顺序**存 `app_settings` 的 `update_source_preference`（auto / giteeFirst /
  githubFirst，设置页「更新源顺序」可选）；`auto` 会读 `update_last_good_provider`
  优先上次成功的源，避免每次都先等一个必然失败的超时。两个 key 由
  `main.dart` 的 `UpdateService.instance.bindSettings(...)` 接到 `DatabaseHelper`，
  不接线则偏好只在本次运行内生效。
- **Gitee 镜像在 CI**：`.github/workflows/flutter.yml` 的 `mirror-gitee` job →
  `scripts/mirror-to-gitee.ps1`（推 main + tag、建 Release、传 release.zip 与
  `.sha256`、写 `update` 孤儿分支的 latest.json、最后匿名复验）。需要 GitHub secrets
  `GITEE_TOKEN`（私人令牌勾 projects）与可选 `GITEE_REPO`。
  **不要给这个 job/step 加 `continue-on-error`**（1.6.2 踩过）：它会把镜像失败显示成
  绿色，让人误以为同步成功，实际 Gitee 上没有 Release 也没有 latest.json。
  GitHub Release 在上一个 job 已经建好，镜像失败不影响发版本身。
  支持 `workflow_dispatch` + `mirror_version` 手动补跑某个已发版版本（从 GitHub
  Release 取产物，不重新构建）。
- **PowerShell 插值坑**（1.6.2 踩过）：`"refs/tags/$tag:refs/tags/$tag"` 里 `$tag:`
  会被当成变量名（冒号属于变量名），插值成 `refs/tags//tags/1.6.2`，git 报
  `无效的引用规格 / invalid refspec`，tag 永远推不上去。**变量后紧跟冒号时必须写
  `${tag}`**，别用 `$tag:`。
- 脚本 `scripts/mirror-to-gitee.ps1` **必须保持纯 ASCII**：PowerShell 5.1 读无 BOM 的
  脚本按 ANSI(GBK) 解码，中文注释会吃掉换行让脚本静默失效（1.6.0 的更新脚本踩过）。
  同理 latest.json 用 `UTF8Encoding($false)` 写成无 BOM，否则 Dart `jsonDecode` 报错。
- 持久化：全部走 SQLite（库 + app_settings 表），无 SharedPreferences。

## 性能红线（P0，2026-09-30 修，勿回退）

- 备份 `createBackup`：`VACUUM INTO` 在线快照 + 3 分钟节流 + 单飞；导出 / 导入 / 重置 / 覆盖导入传 `force: true`。**勿**改回「每次写入关库复制整库」。
- 桌面条 `_recompute`：按渲染指纹去重（内容没变不 notify，倒计时仍逐秒）；**新增渲染字段必须加进 `_renderSignature`**，否则界面不刷新。
- 仪表盘：`getScoreRecords` 支持 `startDate/endDate/limit` + 单次 `setState` + `_loadGeneration` 防并发（勿整周期读进内存）。
- main.dart：浮窗探测 10s 限频、球显隐看门狗 15s；AuthProvider 仅解锁状态变化才 notify。
- **玻璃 `blur` 只给「底下真有东西」的面**（2026-11-23，低配机 30→60fps）：
  页面都是纯色底，纯色模糊看不出差别，但 `blur > 0` 就推一层全窗口
  `BackdropFilterLayer`（`blurSigma > 0` 才 pushLayer），一屏几十个玻璃控件 =
  一帧几十次全窗拷贝。成排控件（`GlassActionButton`/`GlassIconAction`/
  `GlassCheckbox`/`GlassChipControl`/`GlassDropdownField`/底部导航条）统一用
  `denseGlassButtonSettings`（`blur: 0`，其余视觉参数不变）；只有状态栏胶囊、
  下拉浮层、解锁卡片用完整 blur。**勿**改回 `blur: 10/14`。
- **课表进度条用 `PaintProgressBar`**，不要 `AnimatedFractionallySizedBox`：
  后者把进度写进布局约束，每秒重排整条课表（独立引擎+分层窗口，必卡）。
- **U 盘枚举走 Win32**（`GetLogicalDrives`+`GetDriveType`），不要改回逐个
  `Directory.exists()` 探 26 个盘符（每 5 秒在主 isolate 跑，慢盘上卡渲染）。
- **U 盘密钥比对读内存、不查库**（2026-11-26）：`_hasKeyOnDrive` 用
  `_usbKeys`（增删改都经 `loadUsbKeys` 重读，与库始终同步），
  并且 `_startUsbScan` 在「一个密钥都没登记」时整拍直接 return。
  每 5 秒 × 每个盘符一次 SQLite 往返 + 两次文件系统调用，是周期性卡顿来源。
- **`_reloadAfterScoreMutation` 只 notify 一次**（2026-11-26）：`loadRecords` /
  `loadStatistics` 都带 `notify` 参数，这里传 `notify: false` 再统一通知。
  仪表盘直接监听 ScoreProvider、每次通知跑六条查询，两次通知＝十二次查询。
- **评分页用 `context.select` 订阅，不要 `watch` 整个 ScoreProvider**
  （2026-11-26）：本页只依赖「周期 + 允许分值范围规则」（`_ScorePageRules`），
  而 ScoreProvider 每次增删改都 notify。watch 整个 Provider 会让整张评分页
  （全班学生卡 + 十几个玻璃控件）每记一分重建一次。

## 稳定性和数据安全红线（2026-11-23 修，勿回退）

- **Flutter 版本必须钉在 3.47.9**（`.fvmrc` 与 `.github/workflows/flutter.yml` 两处同步）。
  3.50.x 的 Windows 引擎在「桌面课表浮窗」这条路径上必现访问冲突闪退
  （`0xc0000005` in `flutter_windows.dll`，多引擎 + 分层窗口 + 每秒重绘）。
  实测对照：3.47.0 / 3.47.9 = 8~10 次启动全活；3.50.0 / 3.50.1 = 8 次里挂 6~8 次；
  同一份代码换 SDK 结论一致（不是业务代码回归）。CI 若改回 `channel: stable`，
  下个 Release 会重新带病。
- **数据库打开失败必须自愈**（`database_helper.dart` 的 `_initDatabase`）：
  判据只认「坏库」（SQLITE_NOTADB 26 / CORRUPT 11 / malformed / disk image is corrupted），
  命中才 留档 `score.db.broken-<时间戳>` → 最近的 `backups/*.db` 校验（integrity_check）
  → 顶替 → 兜底建空库。**被占用 / 只读 / 无权限一律 rethrow，绝不改名换库**（那才是真丢数据）。
  替换前后都要删 `-wal/-shm/-journal`，否则旧日志会把新库改回损坏。
- **启动不能停在转圈页**：`main.dart` 的 `_beginStartup` 包了 try/catch，失败落到
  `_startupError` → `_StartupErrorPage`（显示原因 + 数据目录 + 重试）。
  新增 Provider 的 init 必须留在这一层里，不要自己 catch 掉。
- **备份恢复先校验再覆盖**（`backup_service.dart` `restoreBackup`）：完整性检查不过直接拒绝；
  覆盖前把当前库留档 `score.db.before-restore-<时间戳>`，失败自动回滚。
- **JSON 导入整段在事务里**（`importFromJson`）：表顺序 `groups → students → score_records`，
  中途任一行不合法就整体回滚。勿改回「先逐表 delete 再逐行 insert」。
- `app_settings.value` 读出来一律 `toString()` 降级：历史库可能是 NULL，`as String` 会在启动路径上炸。

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
- 加按钮：一律用 lib/widgets/glass_buttons.dart —— `GlassActionButton` / `GlassActionButton.icon`（文字/图文）、`GlassIconAction`（纯圆形图标按钮）、`GlassIconFrame`（给 PopupMenuButton 之类套玻璃壳）。不要再直接用 Material 的 TextButton / ElevatedButton / OutlinedButton / FilledButton / IconButton。主操作用 `variant: GlassActionVariant.prominent`；尺寸 / 前景色 / 淡色玻璃分别用 height / padding / foregroundColor / tintColor。玻璃档位由 main.dart 的 GlassTheme 统一取 personalization.glassQuality。**例外**：顶部 HomeStatusBar 胶囊本身已是玻璃，右侧「解锁/密钥/上锁」保持普通 TextButton.icon（胶囊形 StadiumBorder、无额外玻璃背景）。
- 选择控件：lib/widgets/glass_controls.dart —— `GlassSwitchTile` / `GlassSwitch`、`GlassCheckbox(Tile)`、`GlassRadio(Tile)`、`GlassChipControl`、`GlassSegmentedChoice`（内部用官方 `GlassSegmentedControl`，高 40、浅色轨道 + 白色玻璃指示块）、`GlassDropdownField` / `GlassDropdown`（下拉选择：保留 Material 选择行为，关闭态画在玻璃底座上）。Checkbox/Radio 包内没有官方组件，是用 `GlassIconButton` 组合出来的。不要再直接用 Material 的 Switch/Checkbox/Radio/SegmentedButton/Chip/DropdownButtonFormField。
- 平台权限/原生：windows/runner/（runner.exe.manifest、CMakeLists.txt、\*.cpp 通道），Dart 侧通道常量在 services/desktop_window_service.dart:18、desktop_ball_service.dart、tray_service.dart。
- 悬浮球显隐 / 让位：球只是「叫回主窗口」的入口，**主窗口在屏上（isVisible && !isMinimized）就不显示**——判定在 `_refreshBallOnScreen`（main.dart；windowManager.isVisible/isMinimized，窗口事件 `onWindowMinimize/onWindowRestore/onWindowEvent('show'/'hide')` 即时触发，15s 看门狗只兜底），显隐经 `desktop_ball_service.dart` 的 `configure(visible:)` 推给原生；原生淡出/淡入 + 隐藏见 desktop_ball_window.cpp 的 `ApplyVisibility`/`StepFade`/`Paint`（fade 走 `SourceConstantAlpha`，淡出中 `WM_NCHITTEST` 不接点击，窗口只隐藏不销毁）。**胶囊的让位必须跟着球的显隐走**：`desktop_schedule_common.dart` 的 `desktopBallReserve(ballEnabled:, ballVisible:)`（球藏着 → 归零 → 胶囊回正）→ provider `toBarPayload(ballVisible:)` → desktop_bar_channel.cpp 的 reserve 计算 + `StartXSlide`（只改了 x 才滑动 0.14/0.22s，其余改动瞬时）。
- 倒计时 / 提醒语显示时间：设置页 desktop_schedule_settings.dart 两个 NumberChoiceTile（0 = 不显示）→ provider `countdownSeconds`/`hintSeconds`（key `desktop_schedule_countdown_seconds`/`_hint_seconds`；旧 `desktop_schedule_alternate_seconds` 只在尚未写过新键时回退）→ models/desktop_schedule_state.dart 纯函数 `desktopCountdownView()` 按 `now − phaseStart` 求 图三 / 图四 / 都不显示 → provider `countdownView` → payload `countdown_view` → DesktopScheduleWidget.countdownView。
- 退出程序：原生 app_quit.cpp QuitApplicationNow()（RemoveTrayIcon → TerminateProcess）；托盘 / 悬浮球菜单直接调用它，Dart 侧走 tray_service.dart quitNow()（「关闭窗口即退出」经 app_shell_service.dart quitApplication）。**不要**改回 `window_manager.destroy()` 或 `ExitProcess`：前者只是 PostQuitMessage、后者会跑 DLL detach 收尾子引擎，都要 3~5 秒（实测 5.8s vs 0.14s）。
- 打包：本地 `fvm flutter build windows --release`；CI：commit message 以 `build: <版本号>` 开头推 main → flutter.yml:12 触发、:31 构建、:38 取版本、:70 打 tag 并发布 Release zip。用户没有要求的情况下严禁私自发布。

- AI 选学生（花名册识别）：评分页「AI 选学生」→ `lib/pages/score/ai_roster/ai_roster_capture_page.dart`（camera + camera_windows 取景 / file_picker 选图 → 拖动四角裁剪 → `image` 包裁剪压缩）→ `ai_roster_process_page.dart`（左图右规则：打勾/打叉/三角形/空白/有手写内容/分数阈值/自定义文字，互斥项自动取消）→ `AiRosterService.recognize()`（OpenAI 兼容 vision 接口，多轮追问）→ 本地 `roster_matcher.dart` 做**编号归一化匹配**（系统学号 `1` 可匹配花名册 `2401`/`xx01`/`01`）与规则过滤 → 采用后 pop 学生 id 回评分页。
  - 服务商配置在 `lib/services/ai_roster_service.dart`（内置 DeepSeek / Ollama / Qwen / OpenAI / OpenRouter / MiniMax / MiMo + 自定义，baseUrl/model/apiKey 均可改），存 `app_settings` 的 `ai_roster_settings`（JSON，**未升 DB 版本**）；设置入口 `pages/settings/ai_provider_settings.dart`（设置中心 Section.aiProvider）。
  - **模型只做"感知转录"**（每格印刷编号 + 标记 + 数值），匹配/过滤/前缀归一全部在本地，可单测（`test/ai_roster_test.dart`）。改提示词在 `AiRosterService.buildSystemPrompt`；改归一化规则在 `roster_matcher.normalizeRosterNumberMatch`（后缀匹配要求被省略前缀 ≥ 2 位，避免 11 被当成 1 号）。