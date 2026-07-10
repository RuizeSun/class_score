# 评分系统

## 概述

评分系统支持对个人和小组进行量化评分，记录评分原因，并提供统计分析功能。

## 评分记录

### 基本结构

```dart
ScoreRecord {
  targetType: 'student' | 'group',  // 评分目标类型
  targetId: int,                      // 目标ID
  score: double,                      // 分数（可为负）
  reason: String?,                     // 评分原因
  scoreItemId: int?,                   // 评分项目ID（可选）
  customName: String?,                 // 自定义评分名称（可选）
  period: int,                         // 评分周期
  createTime: String,                  // 创建时间
}
```

### 评分目标

1. **个人评分** - 针对单个学生
2. **小组评分** - 针对整个小组（会关联到所有组员）

### 批量评分

支持为多个学生同时添加相同的评分记录。

## 评分项目

### 定义

评分项目是预设的评分模板，包含：

- 名称（如 "迟到"、"早退"、"课堂表现"）
- 默认分数
- 描述

### 用途

- 提供快速评分选项
- 便于统计各类评分的分布

## 评分周期

### 概念

评分周期用于区分不同时间段的评分数据，默认为第1周期。

### 操作

- **切换到下一周期** - 创建新周期，自动清空新周期的记录
- **切换到上一周期** - 查看历史周期数据
- **当前周期** - 存储在 `app_settings.current_period`

### 数据隔离

不同周期的评分记录完全隔离，互不影响。

## 统计分析

### 小组统计

- 计算每个小组的总分
- 按总分降序排列
- 自动排除无成员的"未分组"

### 个人统计

- 计算每个学生的总分
- 按总分降序排列
- 支持按小组筛选

### 高级查询（周期范围排名）

用于期中/期末评优，支持查看指定周期范围内的个人/小组评分总和和排名。

**入口**：统计报表页面 → "高级查询" 按钮

**功能特点**：

- 选择起始周期和结束周期
- 显示首次评分和末次评分的时间
- 支持按个人或小组查询
- 个人查询时支持按小组筛选
- 显示排名列表，前3名有高亮标识

**数据库方法**：

- `getStudentTotalScoresByPeriodRange(startPeriod, endPeriod, groupId)` - 获取指定周期范围内的学生总分
- `getGroupTotalScoresByPeriodRange(startPeriod, endPeriod)` - 获取指定周期范围内的小组总分
- `getScoreTimeRangeByPeriod(startPeriod, endPeriod)` - 获取评分的时间范围

### 高级查询（日期范围筛选）

- 按日期范围筛选
- 按评分周期筛选
- 按目标类型筛选
- 支持小组查询（包含所有组员的记录）

### 分数分布

- 按评分项目分组统计
- 计算总分和记录数

### 平均分数

- 计算总加分和总扣分
- 计算日均正分和负分
- 统计有评分的天数

## 相关文件

- `lib/providers/score_provider.dart` - 评分状态管理
- `lib/providers/score_item_provider.dart` - 评分项目管理
- `lib/database/database_helper.dart` - 数据库查询
- `lib/pages/score/score_input_page.dart` - 评分输入页
- `lib/pages/score/score_records_page.dart` - 评分记录页
- `lib/pages/analysis/statistics_page.dart` - 统计分析页
