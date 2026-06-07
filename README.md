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

## 🛠️ 技术栈

- **框架**: Flutter 3.11+
- **状态管理**: Provider
- **数据库**: SQLite (sqflite_common_ffi)
- **图表可视化**: fl_chart
- **文件处理**: csv, excel
- **桌面端支持**: window_manager, win32

## 📁 项目结构

```
lib/
├── database/          # 数据库操作
├── models/            # 数据模型
│   ├── course_schedule.dart
│   ├── group.dart
│   ├── score_item.dart
│   ├── score_record.dart
│   ├── student.dart
│   └── usb_key.dart
├── pages/             # 页面
│   ├── analysis/      # 统计分析
│   ├── core/          # 核心页面 (首页、解锁、PIN设置)
│   ├── dashboard/     # 仪表板
│   ├── score/         # 评分相关页面
│   ├── settings/      # 设置页面
│   └── student/       # 学生管理
├── providers/         # 状态管理
├── services/          # 服务层 (备份、导入)
└── widgets/           # 通用组件
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

## 📦 数据管理

- **备份**: 支持将评分数据备份为文件
- **导入**: 支持从 Excel/CSV 文件导入学生数据
- **导出**: 支持导出评分记录

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

MIT License
