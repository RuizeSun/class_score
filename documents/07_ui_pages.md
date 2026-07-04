# UI 页面结构

## 页面目录

### core (核心页面)

- **home_page.dart** - 应用主页，根据认证状态显示不同内容
- **pin_setup_page.dart** - PIN码设置页（首次使用或重置）
- **unlock_page.dart** - 解锁页（输入PIN码）
- **usb_key_page.dart** - USB密钥管理页

### dashboard (仪表板)

- **dashboard_page.dart** - 仪表板首页，显示统计数据和快捷入口
- **course_schedule_page.dart** - 课程表查看页

### student (学生管理)

- **student_page.dart** - 学生列表页，支持筛选和批量操作
- **group_page.dart** - 小组页面，显示小组统计

### score (评分)

- **score_input_page.dart** - 评分输入页
- **score_records_page.dart** - 评分记录页
- **score_items_page.dart** - 评分项目管理页

### analysis (分析)

- **analysis_page.dart** - 分析首页（图表分析：含评分项分布饼图、总加分/总扣分统计、日均加分/扣分统计、评分变动记录）
- **statistics_page.dart** - 统计分析页（统计报表：学生/小组总分排名）

### settings (设置)

- **settings_hub_page.dart** - 设置中心页
- **settings_page.dart** - 设置页
- **group_management.dart** - 小组管理
- **student_management.dart** - 学生管理
- **course_schedule_management.dart** - 课程表管理
- **score_items_management.dart** - 评分项目管理
- **period_management.dart** - 周期管理
- **pin_dialogs.dart** - PIN相关对话框
- **usb_key_management.dart** - USB密钥管理
- **personalization_card.dart** - 个性化设置（主题色、窗口行为）
- **system_settings.dart** - 系统设置

## 页面关系图

```
AppEntry (应用入口)
├── PinSetupPage (首次设置PIN)
└── HomePage (主页面)
    ├── DashboardPage (仪表板)
    │   └── CourseSchedulePage (课程表)
    ├── StudentPage (学生管理)
    │   └── GroupPage (小组详情)
    ├── ScoreInputPage (评分输入)
    ├── ScoreRecordsPage (评分记录)
    ├── ScoreItemsPage (评分项目)
    ├── AnalysisPage (分析)
    │   └── StatisticsPage (统计分析)
    └── SettingsHubPage (设置中心)
        ├── GroupManagement (小组管理)
        ├── StudentManagement (学生管理)
        ├── CourseScheduleManagement (课程表管理)
        ├── ScoreItemsManagement (评分项目管理)
        ├── PeriodManagement (周期管理)
        ├── PersonalizationCard (个性化设置)
        ├── PinDialogs (PIN管理)
        ├── UsbKeyManagement (USB密钥管理)
        └── SystemSettings (系统设置)
```

## 通用组件

### PinPad (PIN键盘)

位置：`lib/widgets/pin_pad.dart`
功能：6位数字输入键盘，支持清空和删除

### 状态管理

使用 Provider 进行状态管理，主要 Provider：

- `AuthProvider` - 认证状态
- `GroupProvider` - 小组数据
- `StudentProvider` - 学生数据
- `ScoreProvider` - 评分数据
- `ScoreItemProvider` - 评分项目
- `PersonalizationProvider` - 个性化设置（主题色、窗口行为）
