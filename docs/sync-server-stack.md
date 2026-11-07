# 远端服务端技术栈选型（含本机实测）

> 配套文档：`docs/sync-server-feasibility.md`（可行性分析与同步方案）
> 结论：**用 Dart 写服务端**——不是出于"语言偏好"，而是本项目已经装了 Dart/Flutter 工具链、CI 已配 `subosito/flutter-action`，且实测能打出 6.8 MB 单文件 exe，运维成本和 Node 持平、心智成本和 App 完全一致。

---

## 1. 实测数据（本机 Windows，Dart 3.13.0 / FVM）

用 `shelf + shelf_router + sqlite3` 起了个最小服务端（`/health` + `/sync/push`，SQLite 事务批量插入），结果：

| 项 | 实测值 |
| --- | --- |
| `dart compile exe` 单文件产物 | **6,757,376 字节（6.4 MB）**，零运行时依赖 |
| 内置 SQLite 版本 | **3.51.0**（`sqlite3` 包自带，无需系统装 DLL，不会踩版本坑） |
| 启动到可服务 | < 1 秒 |
| `GET /health` 响应 | 200，**1.1 ms** |
| `POST /sync/push`（3 条事件，事务写库） | 正常接收 |

也就是说：**"单 exe + 一个 db 文件"就能跑**，免装 Node/Python/JVM，免 `node_modules`，免 MSVC 运行时。

---

## 2. 选型矩阵

| 方案 | 上手 | 运维 | 与项目的复利 | 风险 | 结论 |
| --- | --- | --- | --- | --- | --- |
| **Dart + shelf + sqlite3** | 高（同一套语言/心智/CI） | 最低（单 exe） | **共享模型/schema/校验代码** | 生态小，但服务端只需要 HTTP + SQL | ✅ **推荐** |
| Node/TS + Fastify + better-sqlite3 | 中 | 低（需 `node` 运行时或 pkg 打包） | 无 | 依赖树大，Windows 原生编译偶发 | 备选，团队熟 TS 才选 |
| Go + chi + modernc.org/sqlite | 中 | 最低（单 exe） | 无 | 要引入第二语言 | 只在你已会 Go 时划算 |
| Python + FastAPI + SQLite | 高 | 中（venv/uv + 进程守护） | 无 | 打包部署比单 exe 麻烦 | 原型够用 |
| Supabase / Pocketbase 自托管（BaaS） | 低 | 中（Docker + Postgres） | 无 | 离线队列、单调 seq 游标、冲突策略**仍需在客户端手写**；BaaS 只帮你省 CRUD | 不推荐——省的是小事，难的是大事 |

**关键判断**：这个服务端 90% 的价值不在 CRUD，而在"**为每条事件分配全局单调 `seq`、幂等去重、按游标下发**"。任何 BaaS 都不会替你做这件事，所以选型应该优先看"能不能共享客户端的数据模型与校验"，而不是"能不能少写 CRUD"。

---

## 3. 推荐栈（具体到版本）

```yaml
# server/pubspec.yaml
name: class_score_server
environment:
  sdk: ^3.9.0
dependencies:
  shelf: ^1.4.0            # 极简 HTTP 服务，官方维护
  shelf_router: ^1.1.0     # 路由
  sqlite3: ^2.4.0          # 同步 FFI 绑定，自带 SQLite 3.51（实测）
  crypto: ^3.0.0           # 事件签名 / token 哈希
# 可选，按需再加，别一次上全：
#  shelf_static     静态只读看板
#  http              访问外部 API（如 QQ 开放平台）
#  args              CLI 参数（--db / --port）
```

刻意**不用**的东西：

- 不用 ORM（sqlite3 直接写 SQL，和客户端 `database_helper.dart` 的写法一致，两边能对照着看）。
- 不用 Docker 强绑定——Windows 上一台机器双击 exe 就能起，容器是可选部署方式。
- 不用 JWT 库：设备 token 就够了（见 §5），多一层 OAuth 只是给自己加坑。

---

## 4. 仓库结构（monorepo，三包）

```
class_score/
├── lib/                       # 现有 App
├── shared/                    # ★ 新增：App 与服务端共用的纯 Dart 包
│   ├── lib/models.dart        #   Student/Group/ScoreRecord 的 toMap/fromMap + uid 规则
│   ├── lib/events.dart        #   SyncEvent 编解码、lamport 比较、冲突决议（LWW）
│   ├── lib/schema.dart        #   表名/列名常量、协议版本号
│   └── lib/validation.dart    #   分值是 float、period ≥ 1 这类规则，两边同一份
├── server/                    # ★ 新增：服务端
│   ├── bin/main.dart          #   入口：args 解析 + 起服务
│   ├── lib/routes/            #   sync_push / sync_pull / snapshot / read / health
│   ├── lib/store.dart         #   SQLite：事件表 + 物化视图（每表最新状态）
│   ├── lib/auth.dart          #   设备配对码 → token
│   └── test/                  #   协议一致性测试（与客户端对跑）
└── test/                      # 现有 157 个测试
```

App 依赖 shared 的方式：`pubspec.yaml` 里 `class_score_shared: {path: shared}`（path 依赖，不发布到 pub.dev，无需 workspace 特性）。

**这是选 Dart 最实在的红利**：`ScoreRecord.toMap()`、uid 生成规则、LWW 比较函数，客户端和服务端**共用同一份代码**，不会出现"两边对字段理解不一致"的经典事故。协议改了只改一处。

---

## 5. 服务端最小接口清单（约 1200 行 Dart）

| 方法 | 路径 | 作用 | 备注 |
| --- | --- | --- | --- |
| GET | `/health` | App 探活 | 1.1 ms，可高频 |
| POST | `/pair` | 配对码换设备 token | 一次性配对码，5 分钟过期 |
| POST | `/sync/push` | 批量提交事件（≤200 条） | 幂等键 `(device_id, lamport)`；返回 accepted/duplicate |
| GET | `/sync/pull?since=N&limit=500` | 按 seq 增量下发 | 排除 `origin_device_id` 自己的事件，防打环 |
| GET | `/snapshot` | 全量快照（新设备恢复） | 复用现有 `VACUUM INTO` 思路 |
| GET | `/read/ranking?period=3` | 只读排名 | 给看板/Bot 用，App 不用 |
| POST | `/admin/rotate-token` | 吊销/轮换设备 | 丢了电脑能远程踢掉 |

服务端存储就两张表：`events`（只追加，带 `seq INTEGER PRIMARY KEY AUTOINCREMENT`）和 "每表最新行" 的物化表（push 时同事务 upsert）。读接口查物化表，不扫事件日志。

---

## 6. 部署形态

- **OS**：Windows（和 App 同一套生态，学校机房/老师电脑直接跑）。用 **WinSW / NSSM** 注册成 Windows 服务（`sc create` 也行），开机自启、崩溃重启。
- **反向代理 / TLS**：**Caddy**（一行配置自动签证书），或者家里跑不开放公网时用 **Cloudflare Tunnel**——省掉公网 IP、端口映射和证书三件套。
- **数据库**：单个 `server.db`，开 `PRAGMA journal_mode=WAL; synchronous=NORMAL`。每日 `VACUUM INTO` 备份保留 7 份（和 App 现有备份策略一致）。
- **容器（可选）**：`FROM dart:stable AS build` → `dart compile exe` → `FROM scratch` 只 COPY exe + db 卷，镜像约 10 MB。
- **Linux/NAS**：装官方 Dart SDK 后在目标机 `dart compile exe`（Dart 不支持交叉编译，但目标机上编译同样一条命令）。

---

## 7. 容量评估（够用很久）

全校 50 人、每天 500 条评分事件、单台服务器：

- 事件行约 200 字节 → **100 KB/天，36 MB/年**；
- `/sync/pull` 峰值并发 = 同时在改数据的设备数，通常 ≤ 3；
- 单核 2 GB 机器足够，实测 health 1 ms 级别，瓶颈永远在网络而不是服务端。

所以**不要为"将来可能变大"提前上 Postgres**。真要迁移时，`sqlite3` 的 SQL 与 Postgres 差异很小，按 `store.dart` 一个文件重写即可（这也是把 SQL 集中在一个文件的原因）。

---

## 8. 安全要点（和选型相关）

- 设备 token：服务端只存 `sha256(token)`；App 侧用 `win32` 的 `CryptProtectData`（DPAPI）加密后落盘，或至少在 `app_settings` 里标为"不同步"。
- 配对码：单次有效、5 分钟过期、绑定首个请求的 device_id，防止被别人抢先配对。
- 事件完整性：`POST /sync/push` 走 HTTPS 即可，不必给每条事件签名（签名只在多服务端/中继场景才需要）。
- `pin_hash`、`usb_keys` **永不上云**（可行性文档 §5 的白名单）。

---

## 9. 如果最后不选 Dart

判断标准很简单，三条中满足两条就换：

1. 你（或接手的同学）**已经**有 Node/Go 的部署经验，而 Dart 服务端要现学；
2. 已经存在一个跑着别的服务的服务器，运维想统一（比如已经有 PM2/Nginx 在跑 Node）；
3. 将来要把服务端做成多租户 SaaS（此时 Dart 生态的中间件确实薄）。

否则**没有理由在同一个仓库里维护第二套语言**——省下的 6 小时上手时间，会以"两边模型不一致"的形式在半年后连本带利还回来。
