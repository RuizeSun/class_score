# 数据库设计

## 数据库位置

数据库文件位于应用程序所在目录的 `data/` 子目录下，文件名为 `score.db`。

## 表结构

### groups (小组表)

| 字段 | 类型    | 说明       |
| ---- | ------- | ---------- |
| id   | INTEGER | 主键，自增 |
| name | TEXT    | 小组名称   |

### students (学生表)

| 字段           | 类型    | 说明             |
| -------------- | ------- | ---------------- |
| id             | INTEGER | 主键，自增       |
| name           | TEXT    | 学生姓名         |
| student_number | TEXT    | 学号，唯一索引   |
| group_id       | INTEGER | 所属小组ID，外键 |

### score_records (评分记录表)

| 字段          | 类型    | 说明                            |
| ------------- | ------- | ------------------------------- |
| id            | INTEGER | 主键，自增                      |
| target_type   | TEXT    | 目标类型 ('student' 或 'group') |
| target_id     | INTEGER | 目标ID                          |
| score         | REAL    | 分数                            |
| reason        | TEXT    | 评分原因                        |
| score_item_id | INTEGER | 评分项目ID（可选）              |
| custom_name   | TEXT    | 自定义评分名称（可选）          |
| create_time   | TEXT    | 创建时间 (ISO8601)              |
| period        | INTEGER | 评分周期，默认1                 |

### score_items (评分项目表)

| 字段          | 类型    | 说明       |
| ------------- | ------- | ---------- |
| id            | INTEGER | 主键，自增 |
| name          | TEXT    | 项目名称   |
| default_score | REAL    | 默认分数   |
| description   | TEXT    | 描述       |

### course_schedule (课程表)

| 字段        | 类型    | 说明                 |
| ----------- | ------- | -------------------- |
| id          | INTEGER | 主键，自增           |
| weekday     | INTEGER | 星期几 (1-7，周一=1) |
| course_name | TEXT    | 课程名称             |
| start_time  | TEXT    | 开始时间 (HH:mm)     |
| end_time    | TEXT    | 结束时间 (HH:mm)     |

### usb_keys (USB密钥表)

| 字段       | 类型    | 说明       |
| ---------- | ------- | ---------- |
| id         | INTEGER | 主键，自增 |
| token      | TEXT    | 密钥令牌   |
| label      | TEXT    | 标签名称   |
| created_at | TEXT    | 创建时间   |

### app_settings (应用设置)

| 字段  | 类型 | 说明           |
| ----- | ---- | -------------- |
| key   | TEXT | 设置键（主键） |
| value | TEXT | 设置值         |

### 重要设置项

- `pin_hash` - PIN码的SHA256哈希值
- `current_period` - 当前评分周期

## 数据库版本

当前数据库版本为 6，支持从旧版本升级。
