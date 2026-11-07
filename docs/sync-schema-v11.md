# v11：同步元数据 + outbox 捕获（触发器）

## 为什么用触发器捕获，而不是手写"每个写方法都记一笔"

`db.insert / update / delete` 在 `lib/` 里有 **52 处调用，散在 3 个文件**，还有
`student_provider.dart` 里的裸事务。如果每处都手写一遍"写业务表 + 写 outbox"，
只要漏一处就产生**永远不会同步的幽灵数据**，而且这种 bug 只有真同步一次才会暴露。

触发器把捕获下沉到 SQLite 引擎：**任何**写入路径（包括未来新增的、包括事务里的）
都会自动记账，绕过它的唯一办法是 `PRAGMA recursive_triggers`（默认关）或直接改库文件。

## 三个触发器怎么配合

```
INSERT  ──af──► 补齐 uid → 取号（lamport+1）→ 写 rev/rev_device/updated_at → 入 outbox
UPDATE  ──af──► 若本次已是"同步写回"（NEW.rev > OLD.rev）则跳过
                否则取号 → 覆盖 rev → 入 outbox
DELETE  ──bd──► 改成墓碑（deleted_at + 取号）→ RAISE(IGNORE) 取消物理删除 → 入 outbox
```

关键实测结论（本机 sqlite 3.50.1 / sqflite_common_ffi）：

- `PRAGMA recursive_triggers` 默认 **0**，因此 AFTER INSERT 触发器里的
  `UPDATE t SET rev=...` **不会**再触发 AFTER UPDATE，不需要防重入。
- 但如果有人把它打开，同样的写入会直接爆 `too many levels of trigger recursion`。
  迁移里**显式设成 OFF**，等于是把这个隐式依赖写死。
- `json_object / json_group_array` 可用且启用（3.38+ 内建），outbox 的 payload
  直接在 SQL 侧生成，不用把行读回 Dart 再拼。

## 为什么 DELETE 用 BEFORE + RAISE(IGNORE)

SQLite 没有"把 DELETE 变成 UPDATE"的原生语法。BEFORE DELETE 里先打墓碑，
再 `RAISE(IGNORE)` 中止这条 DELETE —— 行就留下来了，删除语义由 `deleted_at` 承担。

代价：调用方 `db.delete()` 的**返回行数会变成 0**（语句被中止）。
现有代码里 `deleteGroup` 等处不校验返回值，但 `deleteStudent` 这类会返回
`int` 给上层计数的地方需要复核——这是本次改动唯一会影响现有语义的点，
验收用例里专门覆盖。

## lamport 计数器放在 `sync_state` 而不是 `app_settings`

`app_settings` 会被用户导入/重置、也会参与"要不要同步"的白名单判断，
把同步自身的元数据混进去，迟早会被某次"清空设置"带走。
单独一张 `sync_state` 更干净，且不受任何业务操作影响。

## 表结构

```sql
-- 每张同步表加四列
ALTER TABLE <t> ADD COLUMN uid        TEXT;
ALTER TABLE <t> ADD COLUMN rev        INTEGER NOT NULL DEFAULT 0;
ALTER TABLE <t> ADD COLUMN rev_device TEXT    NOT NULL DEFAULT '';
ALTER TABLE <t> ADD COLUMN deleted_at TEXT;

-- 行级外键翻译缓存（防止"先到子行、后到父行"时外键悬空）
CREATE TABLE sync_uid_map (
  tbl TEXT NOT NULL, uid TEXT NOT NULL,
  local_id INTEGER NOT NULL, PRIMARY KEY (tbl, uid)
);

-- 待推送事件
CREATE TABLE sync_outbox (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  tbl TEXT NOT NULL, uid TEXT NOT NULL,
  op TEXT NOT NULL, payload TEXT NOT NULL,
  rev INTEGER NOT NULL, rev_device TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- 设备身份 / 游标 / lamport
CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

## 查询侧要跟着改的地方

软删除后，"已删除"的行仍留在表里，因此所有读路径必须加 `deleted_at IS NULL`。
`lib/` 内共有 **21 条针对这六张表的 SQL**，集中在 `database_helper.dart`
（另有 2 条在 `student_provider.dart` 的导入事务里）。逐条加过滤是必须做的，
但风险可控：`deleted_at` 默认 NULL，未发生跨设备删除时行为与现在完全一致。
