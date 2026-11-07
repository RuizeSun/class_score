# 远端服务端同步 + QQBot 扩展：可行性分析与方案

> 状态：设计提案（尚未实现）
> 适用版本：class_score 1.5.1（Windows 单平台，SQLite v10）
> 结论一句话：**可行，但不是"加一个 HTTP 客户端"那么简单**——真正的成本在把散落在各处的直连 SQL 收成一条可拦截的写路径，以及把主键从"自增 int"改成"全局唯一 ID"。

---

## 1. 现状盘点（决定改造难度的六件事）

| 事实 | 位置 | 对同步的影响 |
| --- | --- | --- |
| 数据库是 exe 同级 `data/score.db`，sqflite_common_ffi | `lib/database/database_helper.dart:20-52` | 本地文件库，离线天然可用；同步只能做增量，不能做"远端为准" |
| 主键全是 `INTEGER PRIMARY KEY AUTOINCREMENT` | `database_helper.dart:55-287` | **两台设备各自的 id=1、id=2 是不同的人**，直接同步必然串数据 |
| 写操作分散在三处：DatabaseHelper（15 insert / 7 update / 10 delete）、BackupService（导入导出/重置，14 delete + 5 insert）、Provider 里的裸事务（`student_provider.dart:104-207`、`score_provider.dart:357`） | 见上 | 没有单一"写完即入队"的拦截点，必须先把写路径收敛 |
| 导入/重置会 `DELETE FROM sqlite_sequence` 重置自增 | `student_provider.dart:117-119` | id 会被复用，同步场景下这是灾难性的 |
| 本地时间字符串 `DateTime.now().toIso8601String()` 作为 create_time | `score_provider.dart:211` 等 | 设备时钟不可信，冲突判定不能用本地时间 |
| 浮窗引擎不读数据库（第二引擎只渲染推送状态） | `main.dart:32-39`、`HANDOFF.md` | 天然只有一个写进程，省掉多进程数据库锁问题 |
| 现有网络只有天气（`dart:io HttpClient`，失败回退缓存） | `lib/services/weather_service.dart:113-134` | 已有"失败不影响主流程"的既有范式可以照抄 |

另外几个和同步强相关的隐式约束：

- **删除全是硬删除**（`groups`/`students` 带 `ON DELETE CASCADE`，`backup_service.dart:313-331`）。同步必须引入墓碑（tombstone），否则"另一台设备还留着"这种删除永远收敛不了。
- **app_settings 混装了"业务配置"和"设备本地态"**：`pin_hash`、`use_long_pin`、桌面条外观、天气城市、分析页分栏比例，这些都不该跨设备同步。需要显式白名单。
- **统计是 SQL 聚合**（`getGroupTotalScores / getAverageDailyScores` 等），只要底层 `score_records` 正确收敛，排名自动正确——这是"只同步数据、不同步视图"的最大红利。
- 现有备份链路（`VACUUM INTO` 在线快照 + 3 分钟节流，`backup_service.dart:75-144`）可以在同步前复用，作为"远端覆盖本地"之前的最后一道保险。

---

## 2. 可行的三条路线与取舍

| 路线 | 做法 | 优点 | 致命问题 | 结论 |
| --- | --- | --- | --- | --- |
| A. 整库快照同步 | 定期把 score.db 上传；启动时比对决定拉/推 | 1 天能做完 | 两台设备都改过数据就会**整库互相覆盖**，丢数据不可控 | 仅适合"新电脑恢复"这一场景（可作为 P0 的副产品） |
| B. 表级增量 + 自增 id | 按 id 拉取 delta | 改动小 | 两台设备的 id 语义完全不同，必然串数据 | 不可行 |
| C. **事件日志（op-log）+ 全局唯一 ID + LWW** | 本地先写，写成功即入 outbox；上线后按序推拉 | 离线可用、无覆盖、可审计、天然适配追加型数据（评分记录） | 需要重构写路径与主键 | **推荐** |

**推荐 C**。核心原则：

1. **本地 SQLite 仍是唯一真相（source of truth）**，服务端是"事件搬运工 + 只读副本"，绝不反向接管读写。
2. **网络永远在写路径之外**：任何 `await server.post()` 都不允许出现在 UI 的等待链上，否则"远端离线 → 评分按钮卡住"。
3. **同步失败必须静默降级**：和天气服务一样，失败只改状态栏图标，不影响任何功能。

---

## 3. 目标架构

```
┌───────────── App（Windows, Flutter）─────────────┐
│  UI / Provider（无改动语义）                      │
│        ↓ 写                                         │
│  DatabaseHelper（唯一写入口：写库 + 写 outbox 同一事务）│
│        ↓                                            │
│  score.db（业务表 + uid/updated_at/rev + 墓碑）      │
│  outbox（待推送事件）+ sync_state（游标/设备身份）   │
│        ↓ 后台 SyncEngine（Timer/网络恢复/写入 debounce）│
└────────────┬───────────────────────────────────────┘
             │ HTTPS + Bearer（设备 token）
┌────────────▼──────────── Server ────────────────────┐
│  Fastify/Go + SQLite(WAL) 或 Postgres               │
│  ├─ /sync/push  接收事件（幂等 dedupe）              │
│  ├─ /sync/pull  按 server_seq 增量下发               │
│  ├─ /snapshot   全量快照（新设备恢复 / 服务端重建）    │
│  ├─ /read/*     只读 API（管理网页 / QQBot）         │
│  └─ /health     在线探测（App 状态栏用）             │
│                                                     │
│  QQBot 适配器（NapCat/LLOneBot 或官方开放平台）       │
│  读同一份库 → 查排名 / 推送日报 / 老师指令评分         │
└─────────────────────────────────────────────────────┘
```

服务端"离线"对 App 的影响只体现在一个状态枚举上：

```dart
enum SyncStatus { offline, idle, syncing, error, authRequired }
// 离线：outbox 继续堆积，UI 完全正常，只把状态点画成灰色
```

---

## 4. 数据模型改造（SQLite v11）

### 4.1 业务表加列

每张参与同步的表加三列（`students / groups / score_records / score_items / course_schedule / schedule_adjustment`）：

```sql
ALTER TABLE students ADD COLUMN uid TEXT;          -- 'stu_7f3c…' 客户端生成，全局唯一
ALTER TABLE students ADD COLUMN updated_at TEXT;   -- 逻辑时钟：设备单调计数，不信本机时钟
ALTER TABLE students ADD COLUMN deleted_at TEXT;   -- 非空即墓碑（软删除）
CREATE UNIQUE INDEX idx_students_uid ON students(uid);
```

- `id` 保留，继续做本地外键（`group_id` 仍指向本地 int）——**避免大改所有 join**。
- 跨设备只认 `uid`；收到远端行时用一张 `uid_map(table, uid, local_id)` 做翻译。
- 软删除替代 CASCADE：`students/`groups 删除改为写 `deleted_at`，查询统一带 `WHERE deleted_at IS NULL`（可用视图或 helper 统一拼接，改动集中在 DatabaseHelper）。

### 4.2 新增三张表

```sql
CREATE TABLE outbox (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name TEXT NOT NULL,
  uid TEXT NOT NULL,
  op TEXT NOT NULL,          -- insert | update | delete
  payload TEXT NOT NULL,     -- JSON（不含本地 id，外键已翻译成 uid）
  created_at TEXT NOT NULL,
  retry INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE sync_state (
  key TEXT PRIMARY KEY,      -- server_seq / device_id / device_token / last_sync_at
  value TEXT NOT NULL
);

CREATE TABLE uid_map (
  table_name TEXT NOT NULL,
  uid TEXT NOT NULL,
  local_id INTEGER NOT NULL,
  PRIMARY KEY (table_name, uid)
);
```

### 4.3 事件格式

```json
{
  "device_id": "dev_9a1",
  "lamport": 1042,
  "table": "score_records",
  "uid": "rec_5c2e",
  "op": "insert",
  "data": {
    "target_type": "student", "target_uid": "stu_7f3c",
    "score": 2.0, "reason": "课堂发言", "period": 3,
    "create_time": "2026-10-30T10:12:00", "is_quick": 0
  }
}
```

服务端为每条事件分配全局递增 `server_seq`，App 的游标就是它——**拉取天然有序、可断点续传、可重放**。

---

## 5. 冲突策略（不要迷信"自动合并"）

| 数据 | 性质 | 策略 |
| --- | --- | --- |
| `score_records` | 追加型，只增不改（改动走 `score_record_logs`） | **天然可合并**，按 uid 去重，永不需要解决冲突 |
| `score_record_logs` / `archives` | 追加型 | 同上 |
| `students.name / group_id / student_number` | 覆盖型 | LWW：`(lamport, device_id)` 取大者；被覆盖版本进本地 `sync_conflicts` 表，设置页可查看/还原 |
| `groups.name` | 覆盖型 | LWW，删除走墓碑 |
| `app_settings` | 混合 | **白名单同步**（计分规则、周期号），`pin_hash`/外观/城市等仅本机 |
| 删除 | — | 墓碑优先：`deleted_at` 一旦写入即收敛，物理清理由服务端每日任务在 N 天后执行 |

`lamport` 是每设备的单调计数器（不是墙钟），保证"设备时钟差 3 分钟"不会导致后写的改动被判为旧值。

---

## 6. 同步流程（离线优先的完整状态机）

```
启动 ──► 读 sync_state ──► 有 pending outbox? ──否──► 只 pull（增量）
                                │是
                                ▼
                       在线？──否──► 状态=offline，定时重试（退避 5s→15s→60s→5min）
                                │是
                                ▼
                    push（批量≤200条，幂等键=device_id+lamport）
                                ▼
                    pull（since=server_seq，事务内应用）
                                ▼
                    更新游标 ──► 状态=idle，刷新 Provider（notifyListeners）
```

触发点四处，全部是"尽力而为"，不阻塞 UI：

1. 应用启动后 3 秒（首帧之后，浮窗引擎不启动，见 `main.dart:32`）。
2. 写操作 debounce 5 秒（DatabaseHelper 写完后 `scheduleSync()`）。
3. 定时心跳 60 秒（顺带探活 `/health`）。
4. 窗口获得焦点 / 手动点"立即同步"。

失败处理：捕获一切异常 → `status=offline` → 记日志 → 退避重试。**绝不重试本地已成功的写**，因为写进 outbox 是同一事务，库里一定有一致的事件。

---

## 7. QQBot 与其他服务端附加功能

服务端持有全量数据的只读副本，所以附加功能都是"读一份库、加一个适配层"：

- **QQ 群助手的可选项**
  - 技术选型：自建没有官方群机器人资质时，走 **OneBot v11 适配器（NapCat / LLOneBot）**，QQ 号在个人电脑上登录，服务端通过 WS 收事件；若有企业/学校资质可走官方开放平台。
  - 功能：`@bot 查 张三`（积分与排名）、`/今日`（班级日报、周期进度）、`/排行`（Top10，可选隐藏真名）、`/加分 3 班 李四 +2 课堂发言`（需老师白名单 + 二次确认 + 写回服务端事件流）、每日 20:00 自动播报。
  - 权限：只读默认开放给群成员；写指令必须绑定老师 QQ 白名单，且写操作在服务端生成带 `source=qqbot` 标记的事件，App 下次 pull 时自然拿到。
- **管理网页**：同一进程内 `/web` 只读看板（今日评分、周期排名、单生曲线），比在 App 里做分享省事。
- **云端备份/迁移**：`/snapshot` 存最近 N 份整库快照；换电脑时输入配对码即可全量恢复（复用现有 `backup_service` 的导入逻辑）。
- **多教师协作 / 家长只读**：基于服务端账号 + 设备授权，App 端只需"登录/解除绑定"两个按钮。
- **审计**：所有事件带 `device_id` 与 `lamport`，天然是一份可追溯的操作日志。

---

## 8. 分阶段实施计划

| 阶段 | 内容 | 主要改动文件 | 预估 |
| --- | --- | --- | --- |
| **P0 本地就绪** | v11 迁移（uid/updated_at/deleted_at/墓碑/outbox/sync_state/uid_map）；写路径收敛到 DatabaseHelper；软删除替代 CASCADE；从 `sqlite_sequence` 复位逻辑里去掉破坏性删除 | `database_helper.dart`、`student_provider.dart:104-207`、`score_provider.dart:357`、`backup_service.dart` | 2–3 天 |
| **P1 同步内核** | `SyncClient`（HttpClient + 重试 + 超时）、`SyncEngine`（push/pull/游标/退避）、服务端 MVP（Fastify + SQLite WAL + 设备配对 token） | 新增 `lib/sync/`、`server/` | 4–6 天 |
| **P2 产品化** | `SyncProvider` + 设置页"同步服务"子页（服务器地址/配对码/状态/冲突列表/立即同步）；状态栏离线小圆点；启动接线（`main.dart` AppEntry post-frame，浮窗引擎跳过） | `settings_hub_page.dart:110-126`、`main.dart`、`home_status_bar.dart` | 2–3 天 |
| **P3 扩展** | QQBot 适配器、日报推送、只读网页、云端快照 | `server/bot/`、`server/web/` | 3–5 天 |

总工期约 2 周（不含运维部署）。部署形态建议：一台 2C2G 云服务器 + Docker Compose（app + Caddy 自动 TLS），SQLite 开 WAL 完全够用——全校 50 人 × 每天 500 条事件 ≈ 100 KB/天，一年 36 MB。

**可以先落地的"半价方案"（1 天）**：只做"整库快照上传 + 新电脑一键恢复"，不做增量合并。它解决"数据别丢、换机别手工拷库"，且不触碰任何现有写路径。建议作为 P0 的前置彩蛋。

---

## 9. 风险与对策

| 风险 | 严重性 | 对策 |
| --- | --- | --- |
| 迁移失败导致旧库损坏 | 高 | 升级前强制 `createBackup(force: true)`（已有能力）；迁移在单事务内完成；失败回滚到备份 |
| id 串台（最容易被低估） | 极高 | 不共享自增 id；同步只走 uid；用 `uid_map` 翻译；P0 阶段先补一组"双库交叉导入"测试 |
| 写入路径漏掉某处，产生"不同步的幽灵数据" | 高 | 把 `DatabaseHelper.instance.database` 的直连访问全部消灭（当前 `lib` 内还有 5 处直连，见 `score_provider.dart:357`、`student_provider.dart:104/197` 等）；用 lint/测试断言"无裸 db 写" |
| 设备时钟不一致 | 中 | 一律用 lamport 计数，不用 `DateTime.now()` 判冲突；`create_time` 仅作展示 |
| PIN / 密钥泄露到云端 | 高 | `pin_hash`、`usb_keys` 列入"不同步"白名单；设备用独立配对 token，服务端只存 hash |
| 双向同步打环（A→服务器→B→服务器） | 中 | 每条事件带 `origin_device_id`，服务端不回推给来源设备；App 应用远端事件时**不再写 outbox** |
| 服务端被入侵/误删 | 中 | 服务端只读副本 + 每日快照 + App 侧本地库仍是真相，损失可控 |
| 网络请求拖慢评分 | 高 | 写路径零网络调用（硬性红线）；同步独立 Isolate/Timer，UI 不 await |
| 用户感知不到"没同步" | 低 | 状态栏常驻小圆点 + 设置页最后同步时间 |

---

## 10. 验收清单（写进 test/）

1. 断网启动 → 全功能可用，`status == offline`，outbox 持续增长。
2. 恢复网络 → 5 秒内自动 push+pull，`status == idle`，服务端条数与本地一致。
3. 双库仿真（两个 `dbDirOverride` 临时库）各加 10 条评分记录 → 互相同步后，两边 20 条、排名一致。
4. 同一学生两端改名 → 收敛到 `(lamport, device)` 较大者，另一版本进冲突表。
5. 一端删除学生 → 另一端变墓碑，评分记录不再参与统计，7 天后才物理清理。
6. 服务端返回 500 / 超时 → 不重试爆炸（指数退避），不丢事件，不阻塞 UI。
7. 新设备配对 → `/snapshot` 全量恢复后继续增量同步，id 映射正确。
8. 迁移：v10 库升级到 v11 后，所有历史数据 uid 补齐、计数不变。

---

## 11. 明确不做的事

- 不做"服务端为准"的在线库（一旦断网 App 就废，与需求直接冲突）。
- 不做实时协同编辑（评分记录是追加型，LWW + 日志足够；CRDT 属过度设计）。
- 不把桌面课表/悬浮球/PIN 状态纳入同步。
- 不引入 `dio/http` 包，沿用仓库既有的 `dart:io HttpClient` 风格（`HANDOFF.md` 明确约定新 HTTP 一律放 `lib/services/`）。
