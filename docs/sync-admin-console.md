# 服务端管理后台（Server Admin Console）

> 面向**服务端维护者**，不是教师端。教师端的身份/权限/业务写入口是后续工作
> （见 `docs/teacher-access-design.md`），本方案刻意不碰，避免把两件事混在一起做。

---

## 1. 它解决什么

同步跑起来之后，运维只有两个信息来源：控制台的配对码，和 App 设置页里的
"上次成功时间"。一旦出现"某台设备同步不动了""服务端上这条数据到底对不对"，
没有任何手段查看。

这个后台补三件事：

| 能力 | 用途 |
| --- | --- |
| 看设备 | 哪几台配过、最近活跃、各推了多少事件；可疑就撤销 |
| 看数据 | 服务端物化副本里每一行是什么（含墓碑）；按 uid/内容搜 |
| 改数据 | 修正明显错误的值（比如把 `score` 从 5 改成 8），**并且让所有设备都收到** |

---

## 2. 最关键的一条设计约束

**管理编辑绝不直接改 `latest` 表。**

`latest` 是派生表（事件流的物化结果）。直接改它的后果不是报错，而是：

- 后台显示"已改"；
- 所有设备**永远**看不到这个改动；
- 下一台设备再刷新同一条时，还会把旧值推回来覆盖掉后台的改动；
- 没有任何界面能发现这件事。

所以编辑走的是**和设备推送完全相同的通路**：

```
PATCH → 校验 → BEGIN → 追加一条 events 记录 → upsertLatestRow → 写审计 → COMMIT
```

设备下次 `pull` 就拿到它，走的是既有的、已经被测试覆盖的远端事件应用路径。
**客户端一行代码都没改。**

### 2.1 rev 怎么分配

`rev = (SELECT COALESCE(MAX(rev),0) FROM events) + 1`，`rev_device = 'srv_admin'`。

客户端里 `rev` 是 **Lamport 时钟**（见 `docs/sync-boundaries.md` §3.4）：
每次写入 +1，应用远端事件时抬到远端最大值。服务端作为新的写入者，
取全局最大值 +1 才能保证这条改动在 LWW 比较里胜过所有已知版本——
否则管理员改的值会被某台设备上一个更旧的版本盖回去，而日志里看不出原因。

### 2.2 为什么用 `srv_admin` 这个假 device_id

`_pull` 会**排除请求者自己的 device_id**（防打环的第二道保险）。
如果管理员事件借用某台真实设备的 id，那台设备就永远拉不到管理员的改动。
用一个不对应任何真实设备的 id，所有设备都能拉到。

配套限制：`POST /pair` 拒绝 `device_id` 以 `srv_` 开头，防止有人注册成这个
名字后让管理员事件对自己不可见。

---

## 3. 鉴权

### 3.1 用随机 token，不用账号密码

`bin/main.dart` 的 stdin 已经被"回车 = 发配对码"占用，再加一个交互式密码
提示会互相打架。而 256 位随机 token 本身免疫弱口令，与既有的
`hashDeviceToken` 是同一套模型，不需要引入 PBKDF2。

- 首次启动生成 32 字节 token，**只在控制台打印一次**；
- 库里存 `sha256(salt+token)`（`v2` 前缀），库泄露拿不到明文；
- 控制台按 `T` 轮换，或 `--admin-token <值>` 自带；
- 轮换会**同时吊销所有已登录会话**——换 token 的动机通常是"可能泄露了"，
  这时候留着旧会话等于没换。

### 3.2 登录换成短期会话

登录成功签发 32 字节会话 token，**固定 12 小时过期，不做滑动续期**
（续期会让"忘记关页面"变成永久有效令牌）。浏览器存 `localStorage`，
每个请求带 `Authorization: Bearer <session>`。

**不用 Cookie**：没有环境凭证就没有 CSRF 攻击面，比"Cookie + SameSite +
CSRF token"三件套更简单，也更难写错。

### 3.3 两条鉴权链严格分开

| 凭证 | 查的表 | 能做什么 |
| --- | --- | --- |
| 设备 token | `devices` | `/sync/push`、`/sync/pull`、`/sync/bootstrap` |
| 管理员会话 | `admin_sessions` | `/admin/api/*` |

测试里锁死了这一点：设备 token 访问 `/admin/api/overview` 必须 401，
管理员会话访问 `/sync/push` 也必须 401。合在一起写迟早会把一行设备 token
当成管理员凭证放进去。

### 3.4 登录限流

10 次失败锁 15 分钟（按来源 IP）。token 有 256 位熵，穷举本身不现实；
限流挡的是"日志里漏过一半 token 的猜测"和把服务端当靶子刷，同时也是个告警信号。

### 3.5 默认只允许本机访问

`--admin-allow-remote` 才放开。理由见 `docs/sync-transport-security.md`：
默认是明文 HTTP，管理后台是高价值入口，不该默认对同网段所有人开放。

> **这不是安全边界。** 走反向代理时所有请求都表现为回环。
> 真正的边界是管理员 token。

---

## 4. 允许编辑哪些列

可编辑列 = `spec.columns` 减去三类：

| 排除项 | 例子 | 理由 |
| --- | --- | --- |
| 外键列 | `students.group_id`、`score_records.score_item_id` | payload 里是翻译后的 uid，改错会造出悬空引用，需要目标存在性校验 |
| 多态目标 | `score_records.target_type` / `target_id` | 改它等于把记录挪到别人名下，语义上是"撤销重记" |
| 语义主键 | `app_settings.key`、`schedule_adjustment.date` | 改它等于换一个逻辑对象；这两种列是 `preferLatest` 策略，改了对端同键行会被丢弃 |

结果：

| 表 | 可编辑列 |
| --- | --- |
| `groups` | `name` |
| `students` | `name`、`student_number`、`include_in_group_total` |
| `score_items` | `name`、`default_score`、`description` |
| `score_records` | `score`、`reason`、`custom_name`、`create_time`、`period`、`is_quick` |
| `course_schedule` | `weekday`、`course_name`、`start_time`、`end_time` |
| `schedule_adjustment` | `weekday`、`created_at` |
| `app_settings` | `value` |

保留 `students.student_number` 是有意的：它在客户端是 `renumber` 策略，
撞号时客户端自己会改号，服务端改它不会丢数据。

### 4.1 类型必须与旧值同类

不校验的后果不是"报错"而是"客户端解析出错"：`score` 本来是 REAL，
若被改成字符串 `"5"`，客户端 `as num` 直接抛，那条事件会被计入
"无法应用"，而且**每一轮拉取都会重试同一条**。

所以服务端按原值类型校验（旧值是 `int` 只收 int，`String` 只收 string…），
不符直接 400 并告诉期望类型。

---

## 5. 接口

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| `GET` | `/admin` | 管理页面（静态资源） |
| `POST` | `/admin/api/login` | 管理员 token → 会话 |
| `POST` | `/admin/api/logout` | 删除会话 |
| `GET` | `/admin/api/overview` | 协议版本、各表行数、设备数、事件数、最大 seq、当前配对码 |
| `GET` | `/admin/api/devices` | 设备列表（事件数、最近活跃、最近事件时间） |
| `DELETE` | `/admin/api/devices/{id}` | 撤销设备 |
| `GET` / `POST` | `/admin/api/pairing` | 查看 / 生成配对码 |
| `GET` | `/admin/api/table/{name}` | 分页浏览（`offset`/`limit`/`q`/`deleted=1`） |
| `PATCH` | `/admin/api/table/{name}/{uid}` | 编辑允许列 |
| `GET` | `/admin/api/audit` | 最近 200 条管理操作 |

---

## 6. 前端

`server/web/admin/` 下三个文件：`index.html`、`admin.css`、`admin.js`。
纯 HTML + 原生 JS，**无框架、无构建步骤**。

### 6.1 为什么嵌入 Dart 代码

单文件 exe 是这套服务端的部署形态。运行时去磁盘找 html/css/js 就要求
"exe 旁边必须带着一个目录"，部署说明会立刻多一步，而这一步一定会有人漏。

`server/tool/embed_web.dart` 把三个文件转成 `lib/src/admin_assets.g.dart`：

```bash
cd server
dart run tool/embed_web.dart
```

**忘跑工具会导致"改了页面但服务端还在发旧版"**，而所有测试都还是绿的。
`test/sync_admin_assets_test.dart` 逐字节比对两者，忘跑必挂。

### 6.2 两条前端纪律

1. **只用 `textContent` 写值**。数据来自已配对设备，等同不可信输入；
   拼进 `innerHTML` 等于把 XSS 权限交给任何能配对的人。
2. **未登录不渲染任何数据**。登录框之外的面板在登录成功前是空的，
   会话过期(401)直接退回登录框并重载页面，不留半截数据在屏幕上。

配套 CSP：`default-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'`。
这就是为什么 JS/CSS 必须是独立文件——内联会被自己禁掉。

---

## 7. 审计

上一轮安全问题里有一条"服务端没有审计日志，出事无法追溯"。管理后台正好是
唯一需要人工介入的写入口，所以这里记 `before` / `after`：

```
{ "action": "edit", "table": "students", "uid": "stu_...",
  "before": {"name": "Zhang"}, "after": {"name": "Zhang-edited"},
  "source_ip": "127.0.0.1" }
```

设备同步流量**仍然不审计**（量太大且没有人工介入），这条边界写在这里以免误解。

---

## 8. 验证

自动化（`fvm flutter test`，4 个新文件）：

| 文件 | 覆盖 |
| --- | --- |
| `sync_admin_auth_test.dart` | 未登录 401；错 token 401；会话可用/登出即失效；设备 token 不能当会话（反向亦然）；会话过期 401；库里不可逆；10 次失败 → 429；轮换后旧 token 与旧会话全失效；非回环来源 403 |
| `sync_admin_api_test.dart` | 概览/设备/表分页搜索/含墓碑/配对码/审计；允许列清单（外键与语义主键被排除）；CSP 与无内联脚本；`--no-admin` → 404；`srv_` 前缀被拒 |
| `sync_admin_edit_test.dart` | **端到端**：设备推送 → 管理员 PATCH → 断言追加了 `device_id='srv_admin'` 且 rev 更大的事件 → 设备 pull 应用后本地值已变 → 不回推；墓碑行 400；非法列/类型/uid 400·404；审计含 before/after |
| `sync_admin_assets_test.dart` | 嵌入资源与磁盘逐字节一致；content-type；index.html 引用的资源都已嵌入 |

手工冒烟（真实 `dart run` + curl，已实测通过）：

```
login → 200，拿到 session
POST /admin/api/pairing → 6 位码
POST /pair → 设备 token
POST /sync/push → {"accepted":1,"seq":1}
GET  /admin/api/devices → 设备在列，events=1
PATCH /admin/api/table/students/stu_smoke1 {"name":"..."} → {"ok":true,"rev":2}
GET  /sync/pull (设备 token) → 拿到 rev=2、d=srv_admin 的事件
GET  /admin/api/audit → edit 记录含 before/after 与来源 IP
GET  /admin/api/overview 未带 token → 401
```

---

## 9. 运维手册

```bash
# 启动（推荐开 TLS，见 docs/sync-transport-security.md）
class_score_server.exe --db data/server.db --port 8787 \
  --cert cert.pem --key key.pem

# 首次启动控制台会打印：
#   管理后台: https://0.0.0.0:8787/admin（仅本机可访问）
#   管理员令牌: 3f9c...（只显示这一次）

# 从另一台机器访问后台（例如服务端跑在无人值守的机器上）
class_score_server.exe ... --admin-allow-remote

# 忘了令牌 / 怀疑泄露
#   在控制台按 T 轮换 → 旧令牌与所有已登录会话立即失效

# 完全关掉后台
class_score_server.exe ... --no-admin
```

浏览器打开 `http://127.0.0.1:8787/admin`，粘贴令牌即可。

---

## 10. 已知边界

| 边界 | 说明 |
| --- | --- |
| **LWW 固有语义** | 若某设备上有一行改动从未推送过、且其本地 rev 大于服务端已知最大 rev，该设备会把管理员编辑判为更旧而忽略。这不是缺陷，是"最后写入者胜"的定义。 |
| 墓碑不可编辑 | 恢复由设备端做（回收站语义建立在"墓碑=已删"之上）。 |
| 不建行不删行 | 删除应走设备的墓碑语义；服务端造墓碑会与回收站打架。 |
| 反向代理下回环判定失效 | 所有请求都表现为回环；边界是 token。 |
| 明文 HTTP 下令牌裸奔 | 启动横幅会警告；建议开 TLS。 |
| 设备同步流量不审计 | 只审计管理操作。 |

---

## 11. 明确不做

- 教师账号 / 角色 / 权限
- `/api/score` 之类业务写入口
- 建行 / 删行 / 恢复墓碑
- 实时推送（轮询足够，后端是本地 SQLite）
- 任何新依赖（`crypto` 已在 `server/pubspec.yaml`）
