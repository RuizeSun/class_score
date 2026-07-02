# 班级量化评分管理系统 - 项目概述

## 项目简介

班级量化评分管理系统是一个桌面应用程序，用于管理班级学生的量化评分。系统支持：

- 学生和小组管理
- 评分记录（个人评分、小组评分）
- 评分周期管理
- 课程表管理
- USB 密钥解锁
- PIN 码保护
- 数据备份与恢复
- 数据导入导出

## 技术栈

- **Flutter** - UI 框架
- **Provider** - 状态管理
- **SQLite (sqflite_common_ffi)** - 数据库
- **window_manager** - 窗口管理

## 目录结构

```
lib/
├── main.dart              # 应用入口
├── database/              # 数据库操作
│   └── database_helper.dart
├── models/                # 数据模型
│   ├── student.dart
│   ├── group.dart
│   ├── score_record.dart
│   ├── score_item.dart
│   ├── course_schedule.dart
│   └── usb_key.dart
├── providers/             # 状态管理
│   ├── auth_provider.dart
│   ├── group_provider.dart
│   ├── student_provider.dart
│   ├── score_provider.dart
│   └── score_item_provider.dart
├── services/              # 业务服务
│   ├── backup_service.dart
│   └── import_service.dart
├── widgets/               # UI 组件
│   └── pin_pad.dart
└── pages/                 # 页面
    ├── core/              # 核心页面
    ├── analysis/          # 分析页面
    ├── dashboard/         # 仪表板
    ├── score/             # 评分页面
    ├── settings/          # 设置页面
    └── student/           # 学生页面
```

## 核心概念

### 评分周期 (Period)

系统支持多个评分周期，用于区分不同时间段的评分数据。当前周期存储在 `app_settings` 表的 `current_period` 键中。

### 评分目标 (Target)

评分记录可以针对两种目标：

- `student` - 个人评分
- `group` - 小组评分

### 默认分组

系统使用 `未分组` 作为默认分组，用于存放未分配小组的学生。
