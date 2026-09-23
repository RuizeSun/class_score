<div align="center">

# class_score

一个基于 Flutter 开发的现代化班级量化评分管理桌面应用，提供安全的评分记录、数据分析和管理功能。

![Flutter](https://img.shields.io/badge/Flutter-3.11+-0078D4?logo=flutter)
![Dart](https://img.shields.io/badge/Dart-3.11+-0175C2?logo=dart)
![License](https://img.shields.io/badge/License-MIT-blue.svg)

</div>

## ✨ 功能特性

| 功能模块          | 说明                             |
| ----------------- | -------------------------------- |
| 📊 **主页仪表板** | 概览班级评分状态，快速查看课程表 |
| ➕ **评分管理**   | 灵活添加和管理各项评分指标       |
| 📋 **评分记录**   | 查看历史评分记录，支持查询与追溯 |
| 📈 **统计分析**   | 可视化数据图表，直观展示评分趋势 |
| 🔒 **安全锁定**   | PIN 码保护，防止未授权访问       |
| 🔑 **USB 密钥**   | 支持 USB 密钥快速解锁            |
| ⚙️ **设置中心**   | 课程管理、数据导入导出等配置     |
| 👥 **学生管理**   | 学生信息维护与分组功能           |
| 🗓️ **调休设置**   | 临时把某一天切换到其他星期的课表 |
| 🖥️ **桌面课表**   | 桌面常驻课表胶囊、课间进度、临近上课倒计时与天气 |

## 🛠️ 技术栈

- **框架**: Flutter 3.11+
- **状态管理**: Provider
- **数据库**: SQLite (sqflite_common_ffi)
- **图表可视化**: fl_chart
- **文件处理**: csv, excel
- **桌面端支持**: window_manager, win32, desktop_multi_window
- **天气数据**: Open-Meteo（免费、无需 API Key）

## 📁 项目结构

```
lib/
├── database/          # 数据库操作
├── models/            # 数据模型
│   ├── course_schedule.dart
│   ├── group.dart
│   ├── schedule_adjustment.dart
│   ├── score_item.dart
│   ├── score_record.dart
│   ├── student.dart
│   └── usb_key.dart
├── pages/             # 页面
│   ├── analysis/      # 统计分析
│   ├── core/          # 核心页面 (首页、解锁、PIN设置)
│   ├── dashboard/     # 仪表板
│   ├── desktop_bar/   # 桌面课表浮窗入口
│   ├── score/         # 评分相关页面
│   ├── settings/      # 设置页面
│   └── student/       # 学生管理
├── providers/         # 状态管理
├── services/          # 服务层 (备份、导入)
├── utils/             # 通用算法 (名次计算等)
└── widgets/           # 通用组件
    └── desktop_schedule/  # 桌面胶囊（胶囊外壳 / 常态条 / 横幅 / 倒计时）
```

## 🚀 快速开始

### 环境要求

- Flutter SDK >= 3.11.0
- Dart SDK >= 3.11.0
- 桌面端支持 (Windows / macOS / Linux)

### 安装步骤

1. **克隆项目**

```bash
git clone <repository-url>
cd class_score
```

2. **安装依赖**

```bash
flutter pub get
```

3. **运行应用**

```bash
flutter run -d windows  # 或使用 windows/macos/linux 设备
```

## 📖 使用说明

### 首次启动

1. 设置 PIN 码作为安全保护
2. 添加需要管理的课程
3. 导入学生名单

### 日常使用

1. **评分**: 进入「评分」标签，选择评分项目录入分数
2. **查看记录**: 在「记录」标签中查看所有历史评分
3. **数据分析**: 「统计分析」提供丰富的图表展示
4. **安全管理**: 可随时在上锁/解锁状态间切换

## 🖥️ 桌面课表

设置 → **桌面课表** 可开启一颗常驻桌面的课程胶囊（独立浮窗，不占用主窗口）：

- **胶囊形态**：一颗两端半圆的胶囊，**水平居中悬浮**（宽度固定 720 逻辑像素 × 缩放，不再铺满屏幕宽度），因此桌面左侧的快捷方式始终可见；胶囊之外的区域不显示、也不接收点击，图标照常可用
- **显示位置**：顶部居中（默认，距工作区顶部 16px）/ 中央偏上（工作区约 1/4 高度）/ 底部居中，三者都水平居中
- **常态条**：天气 + 今日课程，当前时段高亮并带进度条（上课中显示「数学 -40min」，课间显示「课间休息 -2min」）
- **临近上课**：距下节课不足设定时间（默认 3 分钟）时，先弹蓝底「即将上课」，随后进入上课倒计时（倒计时明细与「准备上课」提示交替显示，整条背景为进度条）；正式上课瞬间弹「上课」后回到常态条；**下课不提示**
- **可配置**：开关、显示位置、窗口层级（桌面级/置顶显示）、鼠标穿透、不透明度、整体缩放、提前提醒时间、横幅时长、交替间隔、天气城市与刷新间隔
- **天气**：来自 [Open-Meteo](https://open-meteo.com/)（免费、无需 API Key），按城市取当前气温与天气现象；取数失败时回退到上次缓存，不阻塞界面
- **排查日志**：`data/desktop_bar_debug.log`（主窗口与浮窗两个引擎写同一份时间线，超过 256KB 自动重开）

实现要点：浮窗由 `desktop_multi_window` 创建独立引擎，状态由主窗口通过通道推送（浮窗不读数据库）；窗口样式由 `windows/runner/desktop_bar_channel.cpp` 用原生 Win32 完成——无边框、不进任务栏、水平居中定位，并用 `SetWindowRgn(CreateRoundRectRgn(...))` 把窗口**硬裁剪成胶囊**（圆角半径 = 高度一半，与 Flutter 侧 `DesktopScheduleCapsule` 的圆角一致），透明度与鼠标穿透照设置应用；`window_manager` 的通道是进程级全局且任务栏调用依赖 COM，在第二个引擎里使用会导致访问冲突崩溃。

## 📦 数据管理

- **备份**: 支持将评分数据备份为文件
- **导入**: 支持从 Excel/CSV 文件导入学生数据
- **导出**: 支持导出评分记录

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

MIT License
