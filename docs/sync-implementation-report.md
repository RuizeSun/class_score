# 同步功能实施报告（P0 + P1）

> 本次实施的边界：**只做同步**。不做教师远程界面、不做 QQBot、不做 HTTP 业务写入口。
> 目标是把"本地改动 → 服务端 → 另一台设备"这条链路跑通，并且保证服务端离线时
> App 的一切功能都照常。

---

## 1. 交付内容

### 1.1 新增：共享协议包 `packages/sync_protocol`

纯 Dart，无 Flutter 依赖，**App 与服务端共用同一份**：

| 文件 | 内容 |
| --- | --- |
| `protocol.dart` | 协议版本、端点常量、参加同步的 6 张表及其列/外键描述 |
| `event.dart` | `SyncEvent` 编解码、`PushResponse` |
| `lww.dart` | 冲突决议 `compareRevision` / `remoteWins` |

共用是这次选 Dart 写服务端的全部理由：`score_records` 的字段含义、uid 规则、
"rev 大者胜"的裁决逻辑只有一份，不存在两端口径分叉。

### 1.2 客户端 `lib/sync/`

| 文件 | 职责 |
| --- | --- |
| `sync_event_codec.dart` | outbox 行 ↔ 线上事件：**外键本地 id ↔ uid 双向翻译**、多态外键（`target_type` + `target_id`）、父行未到时的占位行 |
| `sync_client.dart` | HTTP 客户端（`dart:io HttpClient`，沿用仓库既有约定），失败一律转成 `SyncException` |
| `sync_engine.dart` | 单例引擎：push/pull、游标、指数退避、心跳、状态机 |

### 1.3 数据库 v11（`lib/database/sync_migration_v11.dart`）

- 6 张业务表各加 `uid / rev / rev_device / deleted_at / updated_at`；
- 新增 `sync_outbox`、`sync_state`、`sync_uid_map`；
- **每张表 3 个触发器**（AFTER INSERT / AFTER UPDATE / BEFORE DELETE），把任意写入
  路径（含事务、含未来新代码）自动记账；
- 升级前自动 `VACUUM INTO` 存一份 `pre_v11_*.db` 作为安全网。

### 1.4 服务端 `server/`

`shelf + shelf_router + sqlite3`，五个端点：

| 端点 | 作用 |
| --- | --- |
| `GET /health` | 探活（免鉴权） |
| `POST /pair` | 一次性配对码 → 设备 token |
| `POST /sync/push` | 批量收事件，`(device, table, uid, rev)` 幂等 |
| `GET /sync/pull` | 按 `seq` 增量下发，**排除来源设备** |
| `GET /sync/bootstrap` | 全量最新状态（新设备接管用） |

### 1.5 UI 接线

- 设置 → **同步服务**（`lib/pages/settings/sync_settings_view.dart`）：配对、状态、待推送数、立即同步、**全量对齐**；
- `SyncProvider` 注册进 `main.dart`，启动时 `configure()`（未配对时直接返回，零成本）；
- **六张同步表的写路径全部接了 `scheduleSync()`**（debounce 5 秒）：评分记录在
  `ScoreProvider._reloadAfterScoreMutation`，学生/小组/评分项/课表/调休在各自 Provider
  的写方法尾部。60 秒心跳只作为兜底，不作为主通道——否则学生在课上被改名，
  老师那边要等一分钟才看得见。

两条同步路径的分工（设置页里是两个按钮）：

| 按钮 | 走什么 | 什么时候用 |
| --- | --- | --- |
| 立即同步 | 增量事件流（outbox → push，pull → 应用） | 平时不用点，自动跑的 |
| 全量对齐 | `/sync/bootstrap` 快照，每行只要最新值 | 游标疑似坏了、本地被还原过、数据看着不对 |

---

## 2. 三个"实测踩出来的"关键决定

### 2.1 捕获用触发器，不在每个写方法里手写

`db.insert/update/delete` 在 `lib/` 里有 **52 处调用**，散在 3 个文件，另有 Provider
里的裸事务。逐一改写的漏点只会在真同步时暴露。触发器把它下沉到 SQLite 引擎。

**代价要说清楚**：`BEFORE DELETE` 里 `RAISE(IGNORE)` 会让 `db.delete()` 返回 0 行。
现有调用方都不校验返回值，但这是本次唯一改变既有语义的点。

### 2.2 INSERT 触发器必须一条 UPDATE 写完 uid 和 rev

第一版把"补 uid"和"取号"拆成两条 UPDATE，结果同一次插入**记了两笔账**（实测
`OUTBOX_ROWS=2`）：第一条 UPDATE 只改 uid、rev 不变，正好满足 AFTER UPDATE 的
`NEW.rev <= OLD.rev` 条件，于是又被记了一笔。

合并成一条 UPDATE 后回到 1 条。这个坑写进了迁移的注释里，改触发器时别再拆开。

### 2.3 应用远端事件必须"静默"，否则打环

远端事件写回本地时，触发器看到 rev 前进了就不记账 —— 但这条规则在
"新建一行"（占位行 / 首次收到某 uid）时**不成立**：INSERT 没有"旧 rev"可比。
所以额外加了 `applying` 开关：`SyncEventCodec.applyRemote` 全程把它置 1，
三个触发器的 `WHEN` 子句都检查这个开关。

服务端还有第二道保险：`/sync/pull` 排除 `device_id = 自己` 的事件。

### 2.4 整库操作必须绕过捕获

导入 500 个学生 = 1000 条事件（导入 + 收尾），重置会留下一整批墓碑让对端跟着删。
`SyncWriteGuard.suppressed` 提供"这不是一次用户编辑"的语义，导入/重置/恢复备份
都跑在里面。副作用是这批写入不同步——对"以本地为准"的整库操作是成立的。

---

## 3. 离线优先到底怎么保证

| 场景 | 行为 |
| --- | --- |
| 服务端关机 | 状态变 `offline`，outbox 继续涨，UI 零影响；退避 5s→10s→…→5min 重试 |
| 打分 | 只写本地库 + 入 outbox，**不碰网络**（写路径零 `await` 网络） |
| 服务端恢复 | 下一轮 push/pull 自动补上；启动时立即跑一轮 |
| 对端长期离线 | 它自己的 outbox 在队列里等着，上线后一次补完 |
| 网络中途断 | 已推成功的从 outbox 删除，未推的保留；游标只在成功响应后推进 |

---

## 4. 验证结果

```
fvm flutter test          → 204 个测试全过（新增 42 个同步相关测试）
fvm flutter analyze       → 0 error（info/warning 均为改动前既有）
fvm dart analyze (server) → No issues found
fvm dart analyze (protocol) → No issues found
fvm flutter build windows → 通过（35.4s）
```

新增测试：

| 文件 | 覆盖 |
| --- | --- |
| `test/sync_migration_test.dart` | 双库对跑：uid 翻译、LWW、墓碑、打环、父行未到、lamport 抬升 |
| `test/sync_e2e_test.dart` | 真起服务端走 HTTP：配对鉴权、幂等推送、排除来源、跨设备收敛 |
| `test/sync_settings_view_test.dart` | 设置页「同步服务」渲染无异常、复用统一骨架、不使用卡片、未配对时按钮禁用 |
| `test/sync_drill_test.dart` | **按真实课堂顺序演练**：建组建人打分 → 改名换组 → 删记录删人，逐表比对两端 |
| `test/sync_polymorphic_fk_test.dart` | 评分记录的 `target_type`（单数）→ 表名（复数）映射，双向 |
| `test/sync_cursor_test.dart` | 游标只由 pull 推进；push 应答的全局 seq 不得当游标 |
| `test/sync_bad_event_test.dart` | 一条坏事件不阻塞同页后续事件、不抛异常 |
| `test/sync_bootstrap_test.dart` | 全量对齐取最新值、不触发回推 |
| `test/sync_tombstone_query_test.dart` | 墓碑行不进入任何业务查询（小组/学生/评分项/记录/课表） |
| `test/sync_tombstone_regression_test.dart` | 回收站恢复、学号复用 |
| `test/sync_overwrite_import_test.dart` | 覆盖导入时旧行成墓碑，新行仍能落库 |
| `test/sync_drill2_test.dart` | 第二轮演练：设置同步、课表 diff、孤儿统计口径同一条链路验证 |
| `test/sync_settings_sync_test.dart` | 计分规则/周期同步；外观与 pin_hash 绝不同步 |
| `test/sync_orphan_records_test.dart` | 删人/删组后统计排除孤儿、明细保留历史 |
| `test/sync_course_diff_test.dart` | 课表保存只产生必要的增删事件 |
| `test/sync_student_number_conflict_test.dart` | 学号撞车改号不丢人；调休按 rev 裁决 |
| `test/sync_schedule_adjustment_test.dart` | 同日改调休、删了再加回来 |

服务端单机实测（`dart compile exe`）：

| 项 | 值 |
| --- | --- |
| 产物 | 7.0 MB 单文件 exe，零运行时依赖 |
| `GET /health` | 200，约 1 ms |
| 幂等推送 | 同批重推 `accepted=0, duplicates=N` |
| 跨设备拉取 | 设备 2 拉到设备 1 的 2 条事件，设备 1 拉自己的为空 |

---

## 5. 排障记录：同步设置页整屏崩溃

**现象**：打开「设置 → 同步服务」后刷屏出现
`RenderBox was not laid out` / `semantics.parentDataDirty` / `Cannot hit test a render box with no size`。

**根因**：`SyncSettingsView` 自己又套了一层 `SettingsSectionScaffold`，而
`SettingsHubPage._buildContent` 已经为每个分项套了一层。骨架内含
`Expanded(child: SingleChildScrollView(...))`，嵌套后内层 Column 拿到的是
**无界高度** → `RenderFlex children have non-zero flex but incoming height
constraints are unbounded` → 内层 Row/TextField 全部没有布局 →
后续每一帧都在对未布局的 RenderBox 做命中测试与语义查询。

**修法**：分项只返回内容本身（与 `PersonalizationView` 等既有分项一致），
页头/滚动/边距全部交给 Hub 的统一骨架。顺带把状态摘要从 `Card` 改成带边框的
`Container`——设置页有"不使用卡片"的统一约定，`settings_layout_test.dart` 会断言这一点。

**防范**：`settings_layout_test.dart` 的 `_sectionTitles` 里加入了「同步服务」，
今后新增分项若重复套骨架或用了卡片，回归测试会直接失败。

---

## 6. 第二轮：真实双设备演练暴露的 4 个缺陷

第一轮只验证了"能收敛"，没验证"按老师真实顺序用一遍会不会出事"。
补了一个逐表比对的课堂演练（`sync_drill_test.dart`）之后，暴露出四个**上线即中招**的问题。

### 6.1 评分记录根本推不出去（最严重）

演练第一条断言就炸了：`no such table: student`。

`score_records.target_type` 存的是单数（`'student'` / `'group'`），代码直接把它当表名
去查 uid，而表名是复数。结果：学生、小组都能正常同步，**只有分数一条都过不去**——
界面上"同步是好的"，只是成绩永远对不上。

修法：协议包里加显式的 `scoreTargetTable()` 映射，推送与拉取两个方向共用。

### 6.2 push 会偷偷吃掉别人的事件

`_push` 把服务端应答里的 `seq` 写进了拉取游标。但应答里那个 seq 是**全局最大序号**，
不是"我这一批"的。别的设备在此之前推过事件时，它已经越过了那些事件——
拿到游标后再 pull，就永久跳过了别人的改动，而两端界面都正常、只是少了几条数据。

修法：`server_seq` 的唯一写入点收敛到 `_pull`（真正拉到那一页才算"看过"）。

### 6.3 一条坏事件能把同步永久卡死

`applyRemote` 抛异常时，拉取循环中断、游标不前进 → 下一轮重新拿到同一条 → 再抛。
后面所有设备的所有改动都进不来，界面上只表现为"同步不动了"。

两个层次都修了：
- `target_id` 这类 NOT NULL 外键解析失败时用 `0` 兜底（不是 `null`），从根上不抛；
- `_pull` 对每条事件单独 try/catch，失败计数并在状态里可见，不中断整轮。

### 6.4 墓碑把唯一索引占死了

删除变墓碑之后，两级故障：
- 学生删掉后学号永远不能再分配（`UNIQUE constraint failed: students.student_number`）；
- 覆盖导入先删旧行再插新行，新行沿用同一学号 → **每一条都失败**，而导入循环里的
  catch 把异常吞掉，界面显示"成功导入 0 人"，没有任何报错。

修法：唯一索引改成部分索引 `WHERE deleted_at IS NULL`（在 v11 迁移里做，老库也能修）。
同时 `restoreArchivedRecord` 改为"把墓碑改回活着"，而不是用原主键重新 INSERT
（那是 `UNIQUE constraint failed: score_records.id`）。

**这四个都不是边角情况，而是日常操作必然踩到的路径。**
教训是：只验证"链路通"不够，要按真实使用顺序把数据走一遍，并逐表比对。

---

## 7. 第三轮：把已知边界逐个收掉

第二轮留下的
"已知边界"里，能修的都在这一轮修了。逐条对应：

### 7.1 计分规则与当前周期：从"完全不同步"到白名单同步

原来改 3 个设置项产生 **0 条**事件。现在 `app_settings` 参与同步，但用
**SQL 触发器里的白名单**过滤，而不是在 Dart 侧过滤——漏一处过滤就会让主题色
跑到别人机器上，而这种问题几乎不可能被发现。

代价是这张表必须补一个自增 `id`（原本以 `key` 为主键，而同步元数据靠 id
定位一行）。迁移里重建了这张表，只搬业务列。

顺带修掉一个隐蔽问题：`setSetting` 原本用 `INSERT OR REPLACE`。SQLite 里那是
"先删后插"，而 v11 之后删除变墓碑 + `RAISE(IGNORE)`，插入会拿到**全新 uid**——
对同步而言等于"这一行被换成了另一个对象"，两端各改一次就永远收敛不到一个值。
现在改成"有就 UPDATE、没有才 INSERT"。

### 7.2 孤儿评分记录：两个报表给出互相矛盾的数字

实测最能说明问题：删掉一个考了 100 分的学生后，

| 报表 | 结果 |
| --- | --- |
| 班级总正分 | **103**（把已删学生的分算进去了） |
| 小组总分 | **3**（按 students 关联，墓碑行 JOIN 不上） |

同一份数据、两个口径。现在统一：**统计聚合一律排除孤儿记录，明细列表保留历史**。

### 7.3 课表整表替换：每次保存都换一批 uid

原来 `replaceAllCourseSchedules` 是"全删再全插"，5 门课换成 1 门产生
**5 条墓碑 + 1 条新增**，且所有 uid 全换——对端看到"整个课表被删掉又重建"。

改成按 `(weekday, course_name, start_time, end_time)` 求差集后实测：

| 场景 | 事件数 |
| --- | --- |
| 内容没变再保存 | **0** |
| 只删一门课 | **1** |
| 新增一门课 | **1** |

### 7.4 占位行：不再无声潜伏

占位行的学号从空串改成 `~pending~<uid>`（空串会让第二个占位行撞唯一索引），
并在设置页显示「异常占位行：N 行」。

### 7.5 一处**更正**：rev 是 Lamport 时钟，不是独立计数器

第二轮说"rev 是各设备独立的计数器，后改的不一定赢"——**这个结论是错的**。

实测：A 连写 10 次得到 rev 1–10；B 应用后 lamport 抬到 10；B 再写得到 **rev 11**。
即每次写入都把全局 lamport +1，应用远端事件时还会抬到远端最大值。

所以 rev 反映的是**因果顺序**：B 看到 A 的改动后再改，B 的 rev 必然更大。
只有在"纯并发"（两端离线各改一次、谁也没看到谁）时才会退化为按 `rev_device`
字符串序裁决。结论修正为：**rev 是逻辑计数，不要拿它当"最后修改时间"展示**，
要展示时间请用 `updated_at`。

---

## 7.6 第四轮：审计发现的 9 个缺陷（已全部修复）

第三轮之后做了一次独立审计，逐条实证（每个结论都跑了探针脚本，不是推演）。
下面每一条都是**实测确认过的**，不是"可能存在"。

### 7.6.1 配对码可被限流哨兵行绕过（高危，实测可利用）

`server/lib/sync_server.dart` 的 `_pair` 只按 code 精确匹配 `pairing` 表，而
失败计数行正是以 `code = '__failed__::<来源IP>'`、`used_at = NULL`、
`expires_at = now + 3650 天` 写进去的。于是**任何人先故意输错一次**，就能拿
`__failed__::<自己的IP>` 当配对码换到有效设备 token：

```
WRONG=401 {"error":"unauthorized"}
SENTINEL_ROWS=[{code: __failed__::127.0.0.1, used_at: null}]
BYPASS_ATTEMPT=200 {"token":"6025ef38...","device_id":"attacker"}   ← 直接发到 token
```

修法两道：① 配对码形状校验（必须 6 位数字）；② 查询加
`code NOT LIKE '\_\_failed\_\_::%'`。

### 7.6.2 pin_hash / 主题色 / 天气城市会被推到服务端（高危，实测泄漏）

触发器里的白名单只管"正常写入"这条路，而首次会合走的是
`snapshotLocalRows` —— **绕开触发器直接扫表**，不看白名单。v11 迁移的
`_backfill` 又给 `app_settings` 的**所有**历史行补了 uid，所以老用户升级后
第一次配对，整张设置表都会上传：

```
ON_SERVER key=pin_hash        value=PIN_SECRET_ABC   ← 解锁凭据离开本机
ON_SERVER key=theme_seed_color value=0xFF6750A4
```

与 `sync-boundaries.md` 里"pin_hash 绝不同步"直接矛盾；现有测试只覆盖了
触发器路径，没覆盖首次会合。修法：`snapshotLocalRows` 对 `app_settings` 加
白名单 `WHERE key IN (...)`，`_backfill` 同步收紧。测试见
`sync_snapshot_whitelist_test.dart`。

### 7.6.3 恢复旧备份后，任何编辑都抛异常（高危，实测抛错）

`importFromJson` 在 `applying='1'` 下 INSERT，INSERT 触发器被 WHEN 挡住 →
新行拿到 **NULL uid**；随后 AFTER UPDATE 触发器
`INSERT INTO sync_outbox ... SELECT r.uid` 直接撞 NOT NULL：

```
IMPORTED_UID_NULL=true
RENAME=THREW: NOT NULL constraint failed: sync_outbox.uid
```

`_backfill` 只在迁移时跑一次，此后没有任何补齐逻辑。修法：`SyncWriteGuard.suppressed`
收尾时（仍在 `applying='1'` 内）调 `SyncMigrationV11.backfillMissingUids`。
测试见 `sync_uid_backfill_test.dart`。

### 7.6.4 `applying` 卡在 1，同步永久静默停摆

标记持久化在 `sync_state` 里，进程死在 `applyRemote` 中途就没有代码复位它。
之后所有写入的触发器 WHEN 都不成立：**编辑照常生效、界面照常刷新、outbox
一条都不涨**。修法：`configure()` 启动时复位；同时把 `applyRemote` 整条包进
事务，失败即整条回滚（此前它先抬 lamport 再写行，失败会留下半写状态）。

### 7.6.5 毒事件让整条链路停摆

不可解码的 outbox 行 `return null` 之后既不推送也不删除，永远卡在队首。
修法：`readOutbox` 直接丢弃这类行并计入 `droppedEvents`（在设置页可见）。

### 7.6.6 游标越过失败事件 = 永久丢数据

`_pull` 原先"逐条 try/catch + 照常推进 `server_seq`"：这条事件再也不会重放，
而提示下一轮成功同步就被清掉。修法：游标只推进到**最后一条成功应用**的事件；
连续失败 3 次才判定毒事件，跳过并写进 `sync_dead_letters`（持久可见）。

### 7.6.7 「全量对齐」修不了它承诺能修的游标

文档让用户在"游标坏了"时点它，但它既不推进也不重置 `server_seq`，点完还从
坏游标继续。修法：对齐完成后把游标抬到服务端 `max_seq`，并清空 outbox /
死信 / 失败计数 —— 快照已是权威状态，残留的旧事件推上去只会把旧值反推回服务端。

### 7.6.8 占位行建不出来，评分记录永久成孤儿

`students` 的占位行把 `group_id` 写成 `null`，而该列是 NOT NULL；配合
`ConflictAlgorithm.ignore`，INSERT 被静默跳过并返回 **0**，占位行根本没建出来。
分数于是指向 `target_id = 0`，学生之后到了也不回填。修法：`group_id` 用 0 兜底，
并且建完强制回读真实 id，建不出来就抛（让上层按失败重试），不再静默写错外键。

### 7.6.9 `setSetting` 仍在用 `INSERT OR REPLACE`

§7.1 声称"已改成有就 UPDATE、没有才 INSERT"，**实际代码没改**。每次写都换一个
新 uid（实测连改 3 次得到 3 个 uid），两端各改一次就永远收敛不到同一个值。
现已真正改为 update-or-insert。

### 7.6.10 服务端加固（同轮）

- **push 逐条隔离**：一条坏事件不再让整批 500（那会让客户端无限重试同一批）。
  改用 SAVEPOINT 逐条回滚，应答新增 `rejected` 计数；未知表名直接拒收。
- **协议版本真的校验了**：`protocol.dart` 一直写着"服务端会拒绝版本不一致的
  客户端"，但服务端从不读 `X-Sync-Protocol`。现在不一致返回 426。
- **请求体上限 10 MB** + 单批 1000 条事件上限（`readAsString()` 原本无界）。
- **优雅关闭**：Ctrl+C 现在先停止接连接、`wal_checkpoint(TRUNCATE)`、再 dispose。
- **事件日志保留策略**：`pruneEvents` 按保留窗口裁剪（保守：只在总量超阈值且
  超出窗口时删），启动时执行 + checkpoint。
- **补索引**：`(device_id,tbl,uid,rev)` 幂等查询与 `rev` 扫描。

---

## 7.7 第五轮：rev 信任边界（已修复）

审计遗留问题清单里最重的一条：**rev 完全由客户端指定**。rev 是 Lamport 逻辑
时钟，设计上必须由写入方编号，但"任意 int64"和"单调递增的小整数"是两回事。
逐条实测后果：

### 7.7.1 服务端全局取号回绕成负数（比预想更糟）

`nextEventRev()` 用 `MAX(rev) + 1` 给管理员编辑取号。实测 Dart 里
`9223372036854775807 + 1 == -9223372036854775808` —— **回绕成负数**，
不是抛异常。也就是说：一台设备推入 `rev = 2^63-1` 后，管理员编辑与所有设备
的后续写入都拿负号，在 LWW 里**永久输**给那条毒事件，且界面上毫无征兆。

修法：push 端拒收 `rev > maxSafeRev`（2^53，协议包新常量）或 `rev < 1` 的事件；
`nextEventRev` 顶到上限时停在上限、绝不 `+1`。

### 7.7.2 客户端 lamport 退化成浮点字符串

触发器取号走 SQL `CAST(value AS INTEGER) + 1`。实测 lamport 顶到 int64 后
SQLite 把结果存成 REAL，`sync_state` 里出现 `'9.22337203685478e+18'`——
该设备此后每次取号都得到同一个浮点数，**本地 Lamport 时钟损坏**，
所有本地写入在 LWW 里永久输。

修法（三层）：
1. 六处触发器的取号 SQL 加上限判断，到顶后不再 `+1`；
2. `applyRemote` 抬 lamport 时钳制到 `maxSafeRev`（仍能赢任何正常行的 LWW，
   但不再逼近悬崖）；
3. `configure()` 启动时检测非整数的 lamport，归位到 `maxSafeRev` 自愈
   —— 已被旧版本污染的设备无需重装。

### 7.7.3 `rev_device` 可冒充 `srv_admin`

配对时只挡了 `device_id` 的 `srv_` 前缀，没挡 `rev_device`。设备可以把自己
的事件标成"管理员改的"，污染审计与追溯。现在 push 端把以 `srv_` 开头的
`rev_device` 改写回来源设备 id。

### 7.7.4 为什么选 2^53

比任何真实课堂的写入次数（每天几千次、用几十年也就 10^7 量级）大十几个
数量级，正常设备永远碰不到；同时离 int64 悬崖有足够距离，钳制后仍留有
约 2^10 次的取号空间（足够撑到下次升级）。JS 安全整数上限是个现成的、
有据可查的值。

回归测试：`test/sync_rev_bounds_test.dart`（服务端 6 条）、
`test/sync_lamport_overflow_test.dart`（客户端 4 条）。

---

## 8. 已知边界（下一阶段要处理的）

1. **删除的返回值**：`db.delete()` 现在返回 0（`RAISE(IGNORE)`），已核查现有调用方
   均不依赖行数；将来新增统计类 UI 时要留意。
2. **未做端到端加密**：依赖 HTTPS / 隧道；`pin_hash`、`usb_keys` 不在同步表内。
3. **服务端未做迁移前备份**：客户端有 `pre_v11_*.db`，服务端只依赖 SQLite 自身。
4. **教师端只读界面未做**：本轮范围是同步，服务端已具备数据，但没有独立的教师端 UI。
5. **回收站与操作历史不同步**：`score_record_archives`、`score_record_logs` 仍是各机各记。
6. **老师端的写入入口未设计**：目前老师端若要写数据，走的还是本地库 + 同步，
   离线冲突依然存在。服务端直写是教师端接入时要做的事。

---

## 9. 怎么用起来

```bash
# 1) 打包成单文件（部署到那台常开的机器）
cd server
fvm dart compile exe bin/main.dart -o class_score_server.exe

# 2) 启动
class_score_server.exe --db data/server.db --port 8787

# 3) App：设置 → 同步服务 → 填 http://<服务端IP>:8787 + 配对码
```

配对成功后，大屏上的每次打分都会在 5 秒内推到服务端；另一台设备配对后自动拉齐。

**配对码是一次性的。** 第二台设备（比如老师的电脑）要接入时，在运行中的服务端
控制台**敲一个回车**就会再生成一个，不必重启、也不会影响已配对的设备：

```
  按回车再生成一个配对码（给第二台设备用）；Ctrl+C 退出
  配对码: 366283（10 分钟内有效，一次性）   ← 回车后新发的
```

服务端启动横幅同时显示已配对设备数，便于确认"那台电脑到底连上没有"。

```
class_score sync server v1
  数据库: .../data/server.db
  监听:   http://0.0.0.0:8787
  已配对: 2 台设备
```
