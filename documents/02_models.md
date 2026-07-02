# 数据模型

## Student (学生)

```dart
class Student {
  final int? id;
  final String name;
  final String studentNumber;
  final int? groupId;  // null 表示"未分组"
}
```

### 特点

- `studentNumber` 可为空，系统会自动生成递增编号
- `groupId` 为 null 时表示未分组（对应数据库中存储为 0）

### 相关文件

`lib/models/student.dart`

---

## Group (小组)

```dart
class Group {
  final int? id;
  final String name;
}
```

### 特点

- 包含一个特殊的默认分组 "未分组"
- 删除小组时，组内学生不会被删除

### 相关文件

`lib/models/group.dart`

---

## ScoreRecord (评分记录)

```dart
class ScoreRecord {
  final int? id;
  final String targetType;  // 'student' 或 'group'
  final int targetId;
  final double score;
  final String? reason;
  final String createTime;  // ISO8601 格式
  final int period;        // 评分周期
}
```

### 特点

- `targetType` 决定 `targetId` 引用的对象类型
- `period` 用于区分不同周期的评分
- `createTime` 使用 ISO8601 格式存储

### 相关文件

`lib/models/score_record.dart`

---

## ScoreItem (评分项目)

```dart
class ScoreItem {
  final int? id;
  final String name;
  final double defaultScore;
  final String description;
}
```

### 用途

- 提供预设的评分项目模板
- 包含默认分数，方便快速评分

### 相关文件

`lib/models/score_item.dart`

---

## CourseSchedule (课程表)

```dart
class CourseSchedule {
  final int? id;
  final int weekday;      // 1-7 (周一=1, 周日=7)
  final String courseName;
  final String startTime; // HH:mm 格式
  final String endTime;   // HH:mm 格式
}
```

### 时间格式

- 使用 24 小时制，格式为 `HH:mm`
- 系统会自动规范化时间格式（如 `8:0` → `08:00`）

### 相关文件

`lib/models/course_schedule.dart`

---

## UsbKey (USB密钥)

```dart
class UsbKey {
  final int? id;
  final String token;
  final String label;
  final String createdAt;  // ISO8601 格式
}
```

### 特点

- `token` 存储在 U 盘的隐藏文件中
- `label` 用于用户标识不同的 U 盘密钥

### 相关文件

`lib/models/usb_key.dart`
