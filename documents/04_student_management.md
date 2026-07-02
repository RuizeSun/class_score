# 学生管理系统

## 功能概述

学生管理系统负责管理班级中的学生信息，包括：

- 学生 CRUD 操作
- 分组管理
- 批量导入学生数据

## 学生数据

### 基本信息

- **姓名** (name) - 必填
- **学号** (studentNumber) - 可选，支持自动生成
- **小组** (groupId) - 可选，null 表示"未分组"

### 学号管理

- 学号在数据库中建立唯一索引
- 重复学号会导致导入失败
- 自动生成规则：取最大学号 + 1
- 支持字符串格式（如 "001", "002"）

## 批量导入

### 支持格式

- CSV 文件 (.csv)
- Excel 文件 (.xlsx, .xls)

### 编码处理

- 自动检测 UTF-8（有无 BOM）
- Windows 系统支持 GBK 编码
- 提供自动编码识别机制

### 表头识别

导入文件需要包含以下列（支持多种命名）：

- **姓名**：姓名、name、学生姓名、名字
- **学号**：学号、student_number、编号、ID
- **小组**：小组、group、分组、组别、所属小组

### 导入模式

1. **追加模式**（默认）
    - 保留现有学生和分数
    - 跳过重复学号
    - 自动创建新分组

2. **覆盖模式**
    - 清空所有学生、分组和分数记录
    - 重新导入所有数据
    - 重置自增ID

### 相关文件

- `lib/providers/student_provider.dart` - 学生状态管理
- `lib/services/import_service.dart` - 导入服务
- `lib/pages/settings/student_management.dart` - 学生管理页面
- `lib/pages/student/student_page.dart` - 学生列表页面
