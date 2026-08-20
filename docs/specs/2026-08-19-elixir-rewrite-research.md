# Lilium Chat Elixir 重写调研

状态：调研稿（research，非实现 spec）
日期：2026-08-19
范围：评估用 Elixir 重写 lilium-chat 后端（当前 CF Worker + 10 Durable Object），单机部署，协议兼容 drop-in replace
权威协议参考：`docs/api-contract.md`（v2.31，唯一 source of truth；自旧 repo lilium-chat 复制）

## 0. 摘要（TL;DR）

**结论：可行，且比预想更可行。** 三个关键事实支撑：

1. **协议面是封闭且稳定的**。外部面 = ~45 个 HTTP 路由 + 3 条 WS 协议（browser `lilium.chat.v2` / bot gateway `lilium.chat.bot.v1` / bot stream）+ JWT/bot-token 鉴权 + S3 presign + 一组错误码。全部由 `docs/api-contract.md` 锁定。drop-in 的边界清晰，不依赖 CF 平台特性（Hyperdrive、Queue、DO 都不在 wire 上）。
2. **PG archive 已经是一个持续同步的完整镜像**。`chat.*` schema 有 23+ 张规范化表（channels/members/messages/events/attachments/invites/dm_pairs/bot_*/pins/invocations/interactions…），生产上由 archive consumer 持续写入。Elixir 版可以直接**把 PG 提升为 primary store，复用现有 schema**——数据迁移从"重写"降级为"校验 watermark + 补少量未归档表"。
3. **fanout 痛点是结构性的，Elixir 恰好是解药**。当前 fanout = DO RPC + lease TTL + retry queue + alarm 扫描（2026-07-01 事故即源于此）。contract 已定义 WS 为 best-effort live push、HTTP 为权威恢复路径——这意味着 fanout **不需要投递保证**，Phoenix.PubSub 的内存广播 + 进程存活即订阅存活，lease/queue/alarm 整套机制整体消失。

**主要代价**：单机 SPOF（需要备份/快速重启策略）；失去 CF 免费层与 hibernation（对单机产品可接受）；需要一次 cutover 窗口（WS 客户端重连）。

**建议**：先做 Phase 0 spike（Phoenix 骨架 + PG primary + 1 条 WS 命令 + conformance harness），2 周内验证 conformance 与 fanout 模型，再决定是否全面投入。估算单人 9–14 周到全量 parity（见 §10）。

---

## 1. 背景：为什么考虑重写

### 1.1 当前架构的复杂度来源

当前实现（`src/`，213 个 TS 文件，~61k 行；测试 133 个文件，~23k 行）是围绕 CF 平台约束设计的：

- **10 个 DO 类**（ChatChannel / UserDirectory / UserConnection / ChannelFanout / ChannelDirectory / InviteDirectory / BotRegistry / BotConnection / BotStreamConnection / DMDirectory），各自私有 SQLite（25 张表）。
- **无跨 DO 事务**（CF 平台事实，见 design spec §0.2）→ 4 套 outbox + 统一 alarm scheduler（`projection_outbox` / `archive_outbox` / `bot_delivery_outbox` / `fanout_queue` + `alarm_jobs`）。
- **WS 必须落在 DO 上**（hibernation）→ `UserConnection` / `BotConnection` / `BotStreamConnection` 三个连接型 DO。
- **fanout 是 DO→DO RPC 链**：`ChatChannel` 提交 event → `ChannelFanout.fanoutEnqueue` → 逐 lease 调 `UserConnection.deliver` → socket 发送；失败进 `fanout_queue` 由 alarm 重试。
- **每 DO 单 alarm、last-write-wins** → 自研 earliest-wins scheduler（`src/do/shared/scheduler.ts`）。

这些在 CF 上都是"官方推荐的 DIY 组合"，但组合出来的系统有三个可观测的结构性痛点：

### 1.2 痛点清单（有事故证据）

| # | 痛点 | 证据 |
|---|------|------|
| P1 | **fanout 链路长、状态多**：lease TTL、stale/transient 分类、retry queue、dead-letter、alarm 扫描，700+ 行单文件（`src/do/channel-fanout/object.ts`） | 2026-07-01 事故：UserConnection lease 过期 alarm 死循环 + ChatChannel dueTable 自旋 + fanout 串行放大 → bill time 25→300 GB-sec，`fanout_queue` 反复扫描 |
| P2 | **重试回路自激**：下游 DO 不健康时 outbox/fanout 无限 churn 直到 dead-letter；free tier rows-written 限额直接打断业务（`Exceeded allowed rows written in Durable Objects free tier.`） | 事故文档 §3.4 + 陈年 pending outbox 表 |
| P3 | **跨 DO 幂等协调**：`POST /channels`、`POST /dms` 因 URL 无 channel_id，幂等要由 UserDirectory DO 协调（状态机 `creating`→`completed`） | design spec §0.6 v3.5 |
| P4 | **alarm 调度纪律**：due 列必须是到期时间、超时任务要 `event_time + TIMEOUT`、stub RPC 必须 await——三条纪律全靠 code review 维持 | 事故文档「教训与预防」 |
| P5 | **运维面复杂**：debug SQL 端点、dead-letter 清理端点、backfill 端点、watermark 监控、两个 Worker + 一个 Queue 的部署矩阵 | `src/routes/debug-*.ts`、事故文档「诊断工具」 |
| P6 | **计费模型**：DO billable duration 对"常驻连接 + 频繁唤醒"敏感，hibernation 唤醒成本不可控 | 事故图二 |

**核心判断**：P1/P2 不是代码质量问题的偶然，而是"分布式 + 无事务 + 平台限额"的必然产物。把系统收拢到单机 + 单数据库后，P1（fanout 变内存广播）、P2（outbox 大减）、P3（单库同事务）、P4（无 alarm 调度器）全部结构性消失。

### 1.3 什么**不是**痛点（重写时不必过度设计）

- 消息量不大（个人项目规模），不需要水平扩展优先的设计。
- contract 已把 WS 定义为 best-effort（HTTP 权威恢复），不需要 at-least-once 投递基础设施。
- 附件二进制在 SeaweedFS，profile 在 ToolBear PG——两者都与运行时平台无关。

---

## 2. 现状盘点（drop-in 必须覆盖的面）

### 2.1 HTTP API（~45 路由，`src/index.ts`）

按域分组（wire shape 全部以 `docs/api-contract.md` 为准）：

| 域 | 路由 |
|---|---|
| Bootstrap/列表 | `GET /bootstrap`、`GET /channels`、`GET /events`（user-scoped） |
| Channel | `POST /channels`、`PATCH /channels/:id`、`POST /channels/:id/dissolve`、`POST /channels/:id/join`、`GET /channels/directory`、`POST /channels/:id/owner-transfer`、`GET /channels/:id` |
| Member | `GET/POST /channels/:id/members`、`GET/PATCH/DELETE /channels/:id/members/:uid` |
| Message | `GET /channels/:id/messages`、`GET /channels/:id/messages/:mid/context`、`GET /channels/:id/events`（gap 恢复） |
| Invite/DM | `POST /channels/:id/invites`、`GET /invites/:code`、`POST /invites/:code/accept`、`POST /dms` |
| Upload/Sticker | `POST /uploads/images/presign`、`POST /uploads/images/:aid/finalize`、`POST /uploads/avatars/*`、`GET/POST /stickers`、`DELETE /stickers/:sid` |
| Bot 管理 | `PUT /bot/commands`、`POST /bots`、`GET/PATCH /bots/:id`、tokens CRUD、`GET/PATCH /admin/bots*`、`GET /commands/directory`、`PATCH /channels/:id/commands/:cid`、`GET /channels/:id/commands` |
| Bot 上传 | `POST /bot/channels/:id/uploads/images/presign|finalize` |
| 运维 | `/internal/debug/*`（5 个，DEBUG_TOKEN 门控） |

### 2.2 WebSocket 协议 ×3

| 协议 | 端点 | 鉴权 | 帧 |
|---|---|---|---|
| Browser `lilium.chat.v2` | `/api/chat/ws` | subprotocol `lilium.chat.v2` + `bearer.<jwt>`；Origin 白名单 | 入：`message.send/edit/recall/delete`、`channel.mark_read`、`session.live_start`、`session.heartbeat`、`command.invoke`、`interaction.submit`、`channel.pin_message/unpin_message`；出：`command_ack`（payload-bearing）、`command_error`、`event`、`read_state_updated`、`user_event my_channels_changed`、stream live frames |
| Bot Gateway `lilium.chat.bot.v1` | `/api/chat/bot/ws` | bot token | `hello/ready` → `delivery`（3 类 kind）→ `delivery_result`（effects）→ `delivery_ack`；`session.effects`、`session.stop_requested`/`session.close` |
| Bot Stream | `/api/chat/bot/channels/:cid/streams/:mid/ws` | bot token | `hello/ready`、`append/append_ack`、`finalize/finalized_ack`、`stream_error`、`ping/pong`；seq/ack 语义（`ack_seq` vs `received_seq`） |

### 2.3 鉴权与身份

- **Browser**：ToolBear JWT（HS256，`JWT_SECRET`），规则见 `src/auth/jwt.ts`：`sub` 必填；`client_id` 存在 → `MACHINE_TOKEN_NOT_ALLOWED`；`managed_session=true` 或 `owner_user_id`/`effective_account_user_id` ≠ sub → `SESSION_NOT_ALLOWED`；`admin` claim。
- **Bot**：token 原文只返回一次，DB 存 SHA-256 hash（`BotRegistry` singleton，`idx_bot_tokens_hash` UNIQUE）。
- **Profile**：只读直连 ToolBear 生产 PG `users` 表（`full_name`/`avatar_url`），batch 50，永不落库（`src/profile/resolve.ts`）。

### 2.4 附件

- SeaweedFS（`s3.kuma.homes`，S3 兼容，public-read）。
- presign = AWS SigV4 query-signed PUT URL（5min TTL）+ 固定 `Content-Type`/`Cache-Control` headers；finalize = 公开 URL HEAD 校验 size/content-type。
- **浏览器直传 S3**——后端只签发 URL 和存 metadata。Elixir 版只要 SigV4 签名算法一致，前端零改动。

### 2.5 关键语义不变量（必须逐条保持）

1. per-channel 单调 UUIDv7 `event_id`（per-DO 计数器版，保同频道顺序）；
2. 幂等：`command_id`（≡ HTTP `Idempotency-Key` ≡ 内部 `operation_id`），同 key 异 body → `409 IDEMPOTENCY_CONFLICT`，命中返回缓存 ack payload（`idempotency_keys.response_json`，不扫 events）；
3. replay 重投影：event 存储只存稳定 id，`message.*` payload 按当前 `messages.status` 重投影（deleted/recalled 安全投影）；
4. message mutation 全部 channel-scoped `{channel_id, message_id}`；
5. WS best-effort live push + HTTP 权威恢复（`GET .../events` gap 恢复、per-channel cursor）；
6. 错误契约：`src/errors.ts` 的 `HTTP_STATUS_BY_CODE` + `RETRYABLE_CODES`，envelope `{error:{code,message,retryable}}`，`X-Request-Id`（`req_<uuidv7>`）；
7. CORS/Origin 白名单（`lilium.kuma.homes` + localhost）；
8. `ROUTE_INDEX_PENDING` 仅 invite-code 路由保留。

### 2.6 数据流全景（现状）

```
Browser/Bot ──HTTP/WS──► Worker(Hono) ──DO RPC──► ChatChannel(channel_id)
                                                    │ SQLite txn: messages/events/...
                                                    │ + projection_outbox + archive_outbox + bot_delivery_outbox
                                                    ▼ alarm flush
                     UserDirectory(user_id)   ChannelFanout(channel_id)   BotConnection(bot_id)
                     (my_channels/stickers)   (leases/queue→UserConnection) (delivery queue→bot WS)
                                                    │
                     archive_outbox ──CF Queue──► archive consumer Worker ──► PG chat.archive_records
                                                                        └──► drain/replay ──► chat.* 规范化表
```

---

## 3. 为什么是 Elixir（适配性分析）

| 需求 | Elixir/OTP 匹配度 |
|---|---|
| fanout 痛点 | **高**。PubSub 广播是 BEAM 的一等公民；订阅=进程存活，无需 lease/TTL；一个慢 socket 不会阻塞其他 socket（进程隔离） |
| 常驻 WS（browser + bot + stream） | **高**。Bandit/Phoenix 原生 WS；每连接一个进程，10k+ 连接单机可承载 |
| 坏 bot 不能拖垮全系统 | **高**。supervisor 树：bot 进程 crash → 只重启该 bot；对比当前"DO 不健康→全链路 churn" |
| 单库事务 + 幂等同事务 | **高**。Ecto 事务内写业务行 + idempotency_keys，无跨 DO 协调 |
| 顺序写（per-channel event 单调） | **高**。per-channel GenServer 天然串行化 |
| 单静态发布物、低内存 | **高**。`mix release` 单二进制；空载几十 MB |
| 协议面封闭（JSON over HTTP/WS） | 中-高。Phoenix Channels 或裸 WebSock 均可；JSON 编解码用 Jason |
| 单机 SPOF | 中。BEAM 不解决硬件故障；需备份 + 快速重启（§7） |

**替代方案对比**（简要）：

- **继续 CF 优化 fanout**（Queue 化、合并 DO）：能缓解 P1/P2，但 outbox/alarm/跨 DO 协调的复杂度仍在，free tier 限额仍在。不解决根因。
- **Node 单机重写**：可行（Fastify + ws），但进程隔离弱（一个坏 bot 事件循环阻塞影响全部），常驻 WS 的内存/稳定性不如 BEAM。
- **Go 单机重写**：可行，但 goroutine 隔离不如进程（无 supervisor 语义），WS 生态弱于 Phoenix。

Elixir 的核心优势恰好落在本项目最痛的两点：**fanout（PubSub）** 和 **常驻连接 + 隔离（进程模型）**。

---

## 4. 目标架构

### 4.1 技术选型

| 层 | 选择 | 说明 |
|---|---|---|
| HTTP/WS | **Phoenix 1.7 + Bandit** | Phoenix Channels 承载 3 条 WS 协议；备选 Plug + WebSock（更轻，但 Channels 的 join/handle_info 模型与"命令→ack→事件"更贴） |
| DB | **PostgreSQL（现有实例）** + Ecto | 提升 `chat.*` archive schema 为 primary（§4.3） |
| 内部消息 | **Phoenix.PubSub**（本地） | per-channel / per-user topic |
| JWT | `joken` 或 `jose`（HS256） | 规则照抄 `src/auth/jwt.ts` |
| S3 SigV4 | `aws_signature_v4`（或自签 ~100 行） | 必须与现有 presign URL 兼容（浏览器直传） |
| 配置 | `config/runtime.exs` + 环境变量 | 对齐现有 `.dev.vars` 语义 |
| 观测 | Telemetry + Prometheus 端点 + Sentry（OTLP 或 Elixir SDK） | 对齐现有 Sentry OTLP 目的地 |
| TLS/域名 | Caddy 或 nginx 前置，`chat.kuma.homes` 不变 | Origin 白名单不变 |
| 部署 | `mix release` 单二进制 + systemd（或 Docker） | 单机 |

### 4.2 进程模型

```
LiliumChat.Supervisor
├── Phoenix.Endpoint (Bandit)
│    ├── HTTP routes (/api/chat/*)
│    ├── BrowserWS.Channel      (per user socket, /api/chat/ws)
│    ├── BotGateway.Channel     (per bot socket, /api/chat/bot/ws)
│    └── BotStream.Channel      (per stream socket)
├── ChannelSupervisor (DynamicSupervisor)
│    └── Channel.<channel_id>   (per channel, lazy start)
│         - 写串行化（message send/edit/...、member 变更、pin）
│         - per-channel event 计数器（UUIDv7 单调）
│         - 提交后 PubSub broadcast("channel:<id>")
├── BotSupervisor (DynamicSupervisor)
│    └── Bot.<bot_id>           (per bot, lazy start)
│         - gateway 连接状态、delivery 队列、offline policy
├── StreamSupervisor (DynamicSupervisor)
│    └── Stream.<channel_id>#<message_id>  (seq/ack buffer、finalize 幂等)
├── ProfileCache               (user_id → UserSummary, TTL)
└── Housekeeping               (pending_attachments 过期、stream expiry、idempotency GC)
```

要点：

- **Channel 进程**是 per-channel 顺序写的 owner（替代 ChatChannel DO 的"单 DO 内事务"角色），但它**不持有状态副本**——状态在 PG，进程只是串行化器 + 事件计数器 + 广播器。进程 crash 重启后从 PG 恢复计数器（`MAX(event_id)`）。
- **socket 即订阅者**：BrowserWS socket join 后向 `channel:<id>` topic 订阅（membership 校验通过的所有 active 频道）；`session.live_start` 语义保留（wire 兼容），内部只是"订阅全部 active 频道"。
- **ETS 表**（只读缓存，可丢失）：membership（user→channels+version）、idempotency 热缓存、user→sockets 映射。

### 4.3 存储：PG 提升为 primary（关键决策）

**现状**：`chat.*` 23 张规范化表由 archive pipeline 持续维护，已是 DO SQLite 的忠实镜像（whitelist 见 `src/archive/payload.ts`，replay 配置见 `archive/src/consumer/replay-tables.ts`）。

**方案**：Elixir 版直接读写现有 `chat.*` schema，只补少量表：

| 需新增/确认的表 | 原因 |
|---|---|
| `chat.read_state(user_id, channel_id, last_read_event_id, updated_at)` | 现网 `my_channels.last_read_event_id` **不在** archive whitelist（已核实 `replay-tables.ts` 无此映射），cutover 需从 UserDirectory DO 导出 |
| `chat.idempotency_keys(operation, operation_id, principal, request_hash, response_json, status, expires_at)` | 现网 `idempotency_keys` 是 runtime 表（blacklist），Elixir 版需要持久化（同事务幂等） |
| `chat.bot_deliveries`（或纯内存 + 离线标记） | 现网 `bot_deliveries` 是 runtime 表；单机后大部分可内存化，保留表用于 crash 恢复 |
| `chat.pending_attachments`（可选） | 5min TTL 短命数据；cutover 窗口内的 in-flight 上传可接受丢失，或补表 |

**archive pipeline 的去留**（开放问题 D2）：
- 选项 A：**退役 raw log**，Elixir 直接写规范化表（事务内）。`chat.archive_records` 保留为历史审计。archive consumer Worker 可下线（或保留 replay/backfill 工具）。
- 选项 B：Elixir 继续 emit `ArchiveRecord` 到 raw log（保持现有工具链/监控不变），consumer 照跑。多一跳，但 cutover 期双实现数据路径一致。
- 推荐：**cutover 期用 B，稳定后切 A**（或直接 A，因为 Elixir 写规范化表是事务性的，raw log 只是审计价值）。

**好处**：
- 数据迁移 = 校验 watermark（`MAX(received_at)` / pending replay count，AGENTS.md 已有监控 SQL）+ 导出 read_state 等未归档表；
- 现有 `archive/scripts/*`（replay/backfill/derive-channels）继续可用；
- 未来若要多节点，PG 已经是共享事实源。

### 4.4 fanout 重设计（核心价值）

**现状路径**（每事件）：

```
ChatChannel txn 提交
 → fanoutEnqueue RPC → ChannelFanout(channel_id)
   → 查 fanout_leases（SQLite）
   → 逐 lease: UserConnection(user_id).deliver RPC
     → 查 live_sessions/leases/socket → socket.send
   → 失败 → fanout_queue 行 + alarm_jobs 行
 → alarm 唤醒 → 扫描 due jobs → 重试/死信/lease 清理
```

**目标路径**（每事件）：

```
Channel.<id> 进程：PG txn 提交（messages + events + idempotency_keys）
 → Phoenix.PubSub.broadcast("channel:<id>", {event_frame})
   → 各 BrowserWS socket 进程收到 → 校验 membership_version（内存/ETS）→ socket.send
 → 同时 broadcast("user:<uid>", {user_event}) 给 membership 变更受影响的用户
```

**对比**：

| 维度 | 现状（CF） | 目标（Elixir） |
|---|---|---|
| 在线判定 | lease TTL + 定期 prune | 进程存活即在线（socket 进程退出即取消订阅） |
| 投递 | DO RPC 链（2 跳）+ 失败重试队列 | 本地进程消息（0 跳 RPC） |
| 顺序 | per-channel 计数器 + 各端无序 | Channel 进程串行提交 + PubSub 按序广播（同 topic 内保序） |
| 多端 | 每端一个 lease | 每 socket 一个订阅（天然多端） |
| 失败处理 | retry queue + dead-letter + alarm | 无需（contract 定义 best-effort；漏收走 HTTP gap 恢复） |
| 状态表 | fanout_leases/fanout_queue/fanout_events/online_sessions | 无（ETS 可丢缓存） |
| 崩溃影响 | DO 不健康→全链路 churn（P2） | 单 socket 进程 crash 只影响该连接 |

**membership 门禁**：广播时帧内携带 `membership_version_at_event`（与现网一致）；socket 端用 ETS 缓存的本地 membership version 快速判定，不匹配则走 HTTP resync（保留 `user_event my_channels_changed` hint 语义）。membership 变更事务提交后，向受影响用户的 `user:<uid>` topic 广播 hint——替代现在 `UserConnection /internal/live-memberships-changed` RPC。

**stream live frames**：同 `channel:<id>` topic，live-only 语义不变（`stream_event` 帧）。

**bot gateway 投递**：`Bot.<bot_id>` 进程在线（socket 已连接）→ 直接投 mailbox；离线 → 按 contract 的 offline policy（precheck `BOT_OFFLINE` / 已 commit 短 TTL / passive drop）。替代 `bot_delivery_outbox` + alarm flush。

### 4.5 DO → Elixir 映射表

| 现状（CF） | 目标（Elixir） | 备注 |
|---|---|---|
| `ChatChannel` DO（channel_id） | PG `chat.*` 表 + `Channel.<id>` GenServer | 状态在 PG；进程只管顺序/计数/广播 |
| `UserDirectory` DO（user_id） | PG（channel_members/personal_stickers/attachments/read_state） | my_channels → channel_members + read_state |
| `UserConnection` DO（user_id） | BrowserWS socket 进程 + ETS | hibernation 概念消失 |
| `ChannelFanout` DO（channel_id） | Phoenix.PubSub topic `channel:<id>` | lease/queue 全消失 |
| `ChannelDirectory` / `InviteDirectory` / `DMDirectory` | PG 表（channels/invites/dm_pairs） | 单库后无 ROUTE_INDEX_PENDING lag（可保留错误码语义） |
| `BotRegistry` singleton | PG 表（bot_apps/bot_tokens/bot_commands…） | token hash 查询同 SQL |
| `BotConnection` DO（bot_id） | `Bot.<bot_id>` GenServer | delivery 队列内存化 |
| `BotStreamConnection` DO | `Stream.<cid>#<mid>` GenServer | seq/ack/finalize 幂等逻辑直译 |
| `SchedulerProbe`（test） | GenServer timer | — |
| 4 套 outbox + alarm scheduler | 事务内直写 + （可选）bot_deliveries 表 + Housekeeping 进程 | projection/archive outbox 消失 |
| CF Queue + archive consumer | 事务内写 PG（或过渡期保留 raw log） | §4.3 |
| Hyperdrive（ToolBear PG） | 直接 PG 连接（只读） | 同一库，少一层 |
| miniflare 测试 | ExUnit + 真实 PG（test 库）+ 黑盒 conformance 套件 | §11 |

### 4.6 消失的东西（复杂度预算）

- 10 个 DO 类 + 25 张 SQLite 表 + per-DO migrations 框架
- 4 套 outbox + 统一 alarm scheduler + due-table 纪律
- lease TTL / prune / stale-transient 分类 / dead-letter 运维
- DO RPC 错误分类（`remote/retryable/overloaded`）
- hibernation 唤醒测试、`serializeAttachment` 游标持久化
- CF Queue + 第二个 Worker 的部署/监控
- free tier rows-written 限额风险

---

## 5. Drop-in 兼容性清单（验收标准）

| # | 项 | 验收方式 |
|---|---|---|
| C1 | 域名 `chat.kuma.homes`、TLS、CORS、Origin 白名单 | 前端零改动 |
| C2 | 全部 HTTP 路由 wire shape（`docs/api-contract.md` v2.31） | conformance 套件（§11） |
| C3 | 70 个错误码 + HTTP status 映射 + envelope `{error:{code,message,retryable}}` + `X-Request-Id`（`req_<uuidv7>`） | conformance（`src/errors.ts` 为参照清单） |
| C4 | Browser WS subprotocol 协商（`lilium.chat.v2` + `bearer.<jwt>`）+ 全部帧（含 payload-bearing `command_ack`） | WS conformance |
| C5 | Bot Gateway（hello/ready、3 类 delivery、effects、`session.stop_requested`）+ Bot Stream（seq/ack、finalize 幂等、`ack_seq`/`received_seq` 分离） | WS conformance |
| C6 | JWT 规则边界（`MACHINE_TOKEN_NOT_ALLOWED` / `SESSION_NOT_ALLOWED` / `admin` claim） | 单测 + conformance |
| C7 | presign URL 可被现有前端直接 PUT 成功（SigV4 签名兼容） | 真实 S3 上传 E2E |
| C8 | 幂等语义（同 key 同 body 重放返回缓存 ack / 异 body `409 IDEMPOTENCY_CONFLICT` / 不扫 events） | conformance |
| C9 | per-channel event 单调 + `GET .../events` gap 恢复 + replay 重投影（deleted/recalled 安全投影） | conformance |
| C10 | profile 解析（ToolBear PG 只读，batch 50） | 集成测试 |
| C11 | 数据：cutover 后 bootstrap / messages / events 与旧实现一致 | 黄金对比（§11） |
| C12 | 观测：Sentry 事件、request id、关键指标可查 | 运维验收 |

**明确不需要兼容的**（平台内部，wire 不可见）：DO 拓扑、outbox 表、alarm 调度、hibernation、CF Queue、`/internal/debug/*` 端点（可选保留，方便运维习惯）。

---

## 6. 数据迁移与 Cutover

### 6.1 迁移内容

| 数据 | 现状位置 | 动作 |
|---|---|---|
| 23 张归档域表（channels/members/messages/events/attachments/mentions/invites/dm_pairs/personal_stickers/bot_*/pins/invocations/interactions/stateful_*/audit_logs/message_edits…） | PG `chat.*`（archive pipeline 持续同步） | 校验 watermark：`SELECT COUNT(*) FROM chat.archive_records WHERE applied_at IS NULL` = 0；`MAX(received_at)` 接近 cutover 时刻 |
| `read_state`（`my_channels.last_read_event_id`） | **仅 DO SQLite**（不在 archive whitelist，已核实 `replay-tables.ts`） | cutover 前经 debug SQL 端点批量导出 → 导入 `chat.read_state` |
| `idempotency_keys` | 仅 DO SQLite，短命（有 expires_at） | 可接受丢失（cutover 窗口内 in-flight 幂等键）；或一并导出 |
| `pending_attachments` | 仅 DO SQLite，5min TTL | 可接受丢失；或导出 |
| `bot_deliveries` / fanout / lease 状态 | 运行时 | cutover 时丢弃（WS 重连恢复） |
| 附件二进制 | SeaweedFS（不变） | 无动作 |
| Bot 端 | 连 WS 的 bot 断开重连 | 通知 bot 方（或接受自动重连；协议支持 `last_received_delivery_id` 续传） |

### 6.2 Cutover 步骤（推荐：维护窗口 + 回滚路径）

1. **T-1d**：Elixir 版以**只读**模式上线（同一 PG，读路径 shadow 对比响应，验证 C2/C9/C11）。
2. **T-0（窗口开始）**：旧 Worker 冻结写路由 → 校验 archive watermark 追平 → 导出 read_state 等缺口数据 → 导入。
3. **T-0+**：前置代理切到 Elixir 版（写路径开放）→ 浏览器 WS 重连（HTTP 权威恢复保证无数据丢失）→ bot 重连续传。
4. **观察 24–48h**：错误率、fanout 延迟、Sentry、`GET .../events` 恢复流量。
5. 旧 Worker 保留 1–2 周（DNS 切回即回滚；**回滚仅适合窗口早期**——窗口后期回滚需要反向同步 Elixir 写入的增量，故窗口要短）。

**双跑（dual-run）替代方案**：按 user_id 灰度，两边写同一 PG。不推荐：channel 是共享实体，按用户切分不能隔离 channel 写（两个用户同时在一个 channel 发消息 → 双写）。维护窗口更简单。

### 6.3 窗口内风险

- **in-flight 消息**：WS 命令未 ack 的，客户端重连后按 contract 用同一 `command_id` 重试 → 幂等命中（若幂等键已导出）或重新提交（新 event，客户端靠 `command_id` 关联去重——与现网断线重试语义一致）。
- **bot delivery**：已 commit 未投递的 invocation，bot 重连后按 `last_received_delivery_id` 续传（协议已支持）。
- **stream 中**：in-flight 的 stream 按 abandon 语义收口（contract v2.25 已定义）。

---

## 7. 风险与缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| 单机 SPOF（硬件/进程） | 中 | 每日 PG 备份 + `mix release` 秒级重启 + systemd 自动拉起 + uptime 监控；可选第二机冷备（同 PG，先拉起者服务） |
| 内存上限（WS 连接数） | 低-中 | BEAM 单连接 ~10–50KB 量级，10k 连接 < 1GB；设连接上限 + 超限 503；产品规模远低于此 |
| contract 漂移（实现与 v2.31 不一致） | 中 | conformance 套件从 contract 生成用例（§11）；CI 对照 `docs/api-contract.md` 修订记录 |
| 单机写吞吐瓶颈 | 低 | PG 事务 + 单库，个人项目规模余量大；per-channel 串行只约束同 channel |
| Elixir 团队熟悉度 | 中 | Phase 0 spike 先验证；代码量比现网小（§10 估算） |
| SigV4 presign 兼容细节（header 规范化、scope region） | 中 | 用与现网相同的 AWS SigV4 规范；E2E 真实 S3 上传验证（C7） |
| 双写/回滚窗口数据不一致 | 中 | 窗口短 + 只读 shadow 期 + watermark 校验；回滚仅限窗口早期 |
| 失去 CF hibernation 的"免费常驻" | 低 | 单机内存常驻本就是单机成本模型的一部分 |
| `unsafe-markdown` 等 bot 权限细节遗漏 | 低 | conformance 覆盖 bot 域（C5）；`src/contract/*.ts` 类型定义作为参照 |

---

## 8. 运维模型

| 项 | 方案 |
|---|---|
| 部署 | `mix release` 单二进制 + systemd（或 Docker）；`chat.kuma.homes` 前置 Caddy/nginx 不变 |
| 备份 | PG `pg_dump` 每日 + WAL 归档（若已有）；附件在 SeaweedFS（不变） |
| 监控 | Telemetry → Prometheus 端点；关键指标：WS 连接数、per-topic 订阅数、PG 事务 p99、PubSub 广播延迟、stream 活跃数、idempotency 冲突率 |
| 告警 | 进程重启次数、PG 连接池耗尽、内存阈值 |
| Sentry | Elixir SDK 或 OTLP 直发（现有目的地 `sentry.kuma.homes/api/9/...`） |
| 调试 | 保留 `/internal/debug/*` 等价端点（DEBUG_TOKEN 门控），降低运维习惯切换成本 |
| 日志 | JSON 结构化日志（对齐现有 `console.log` 事件名：`fanout_lease_deleted` 等可保留语义） |

**不再需要的运维动作**：outbox dead-letter 清理、alarm spin 巡检（`alarm_ms < now_ms`）、free tier rows 限额监控、两个 Worker 的独立部署。

---

## 9. 开放问题（需决策）

| # | 问题 | 选项 | 倾向 |
|---|---|---|---|
| D1 | 是否保留旧 CF Worker 作热备 | 保留 1–2 周冷备 / 直接下线 | 冷备 1–2 周后下线 |
| D2 | archive raw log pipeline 去留 | A: Elixir 直写规范化表，raw log 退役 / B: 过渡期继续 emit raw log | cutover 期 B，稳定后 A（§4.3） |
| D3 | `read_state` 导出方式 | debug SQL 端点批量导出 / 新加只读导出端点 | 用现有 debug SQL 端点（`sql-all` 按 user 枚举） |
| D4 | 单机还是双机冷备 | 单机 + 快速重启 / 双机 + 锁 | 先单机；双机冷备作为后续可选项 |
| D5 | Phoenix Channels vs 裸 WebSock | Channels（join/handle_info 模型贴合命令-ack）/ 裸 WebSock（更轻） | Channels |
| D6 | 是否保留 `/internal/debug/*` | 保留（运维习惯）/ 用 `iex` + PG 替代 | 保留核心 2–3 个 |
| D7 | bot `message_event` 离线 drop 语义在单机的实现 | Bot 进程 mailbox 有界队列 + 离线标记 | 照 contract offline policy 直译 |

---

## 10. 分阶段实施计划与工作量估算

以单人、熟悉 Elixir 为前提；每阶段含 conformance 用例补齐 + typecheck 等价（编译 + 测试）。

| 阶段 | 内容 | 估算 |
|---|---|---|
| **Phase 0：Spike（go/no-go）** | Phoenix + Bandit + Ecto 骨架；`GET /bootstrap` + `GET /channels/:id` 只读；JWT 鉴权；PG 连接；SigV4 presign 验证（C7）；conformance harness 雏形（§11）；1 条 WS 命令（`channel.mark_read`）+ 1 条 fanout（`user_event`）验证 PubSub 模型 | 1.5–2 周 |
| **Phase 1：读路径全量** | 全部 GET 路由（channels/messages/events/context/members/directory/invites preview/stickers/bots/commands）+ profile 解析 + 错误契约 + CORS/Origin | 2 周 |
| **Phase 2：写路径核心** | Channel 进程 + per-channel event 计数器 + 幂等（同事务）+ `message.send/edit/recall/delete` + `channel.mark_read` + fanout 广播 + membership 门禁 + replay 重投影 | 2.5–3 周 |
| **Phase 3：Channel/Member/Invite/DM** | channel CRUD、dissolve、join、owner-transfer、member 管理、invite、DM get-or-create、`system.notice` | 2 周 |
| **Phase 4：Upload/Sticker** | presign/finalize（images + avatars）、sticker 库、blurhash 透传、S3 HEAD 校验 | 1–1.5 周 |
| **Phase 5：Bot 域** | BotRegistry 等价（token/commands/manifest）、developer/admin bots API、command.invoke、interaction.submit、rich UI components、pin | 2–2.5 周 |
| **Phase 6：Bot Gateway + Stream WS** | `Bot.<bot_id>` 进程、delivery 队列、effects 路由、offline policy、stateful session、`BotStream` 进程（seq/ack/finalize 幂等） | 2–2.5 周 |
| **Phase 7：Cutover** | 只读 shadow 期、read_state 导出、维护窗口切换、观察期、回滚预案 | 1 周（含观察） |
| **合计** | | **约 14–17 周**（乐观 12 周，若 bot 域可砍范围） |

**可砍范围（若时间紧）**：bot 域（Phase 5/6）可最后做，先让 browser 聊天全量上线；`/internal/debug/*` 可延后。

---

## 11. Conformance 测试策略（关键基础设施）

**核心思路**：把 `docs/api-contract.md` 变成可执行的黑盒测试套件，对旧 Worker 和新 Elixir 实现**双跑对比**。

1. **契约用例生成**：从 `docs/api-contract.md` 的路由表 + 错误码表 + WS 帧定义，生成 HTTP/WS 请求-响应对（fixture 化）。
2. **黄金对比**：同一组请求打到旧 Worker（`chat.kuma.homes`）和新实现（本地），diff 响应（忽略 `request_id`、时间戳、`created_at` 等易变字段）。
3. **WS 会话脚本**：用 `command_id` 幂等 + per-channel cursor 驱动，覆盖 send/edit/recall/delete/mark_read/live_start/heartbeat 的完整状态机。
4. **Bot 域脚本**：hello/ready → delivery → delivery_result → delivery_ack 全链路 + stream seq/ack。
5. **回归锚点**：现有 133 个 vitest 文件（~23k 行）作为语义参照——不必逐条移植，但**边界用例**（幂等冲突、membership 门禁、replay 重投影、stream finalize 幂等）必须在新套件中有等价用例。

**验收门槛**：conformance 套件全绿 + 黄金对比 diff 为空（除白名单字段）+ 真实 S3 上传 E2E 通过。

---

## 12. 结论与建议

**可行性：高。** 协议面封闭稳定、PG 已是完整镜像、fanout 痛点恰好被 BEAM 进程模型结构性解决。重写不是"重写业务逻辑"，而是"把分布式 DO 系统收拢为单进程 + 单库"，业务语义（contract v2.31）保持不变。

**建议路径**：
1. **立即**：做 Phase 0 spike（1.5–2 周），验证 conformance harness + PubSub fanout + SigV4 三个关键假设。
2. **go/no-go 判据**：spike 中 `channel.mark_read` + `user_event` fanout 通过 conformance、真实 S3 上传成功、内存/延迟符合预期 → 全面投入。
3. **投入**：按 §10 分阶段，优先 browser 聊天全量（Phase 1–4），bot 域（Phase 5–6）可延后。
4. **cutover**：维护窗口 + 只读 shadow + read_state 导出，§6 流程。

**最大收益**：fanout 从"DO RPC 链 + lease + retry queue + alarm"（700+ 行、有事故史）简化为"PubSub 广播 + 进程存活即在线"，P1/P2/P4 三类结构性痛点整体消失；代码量与运维面显著下降。

**最大代价**：单机 SPOF（需备份 + 快速重启兜底）+ 一次 cutover 窗口（WS 重连）。

---

## 附录 A：现网关键文件索引（重写参照，旧 repo）

以下路径相对旧 repo `../../../lilium-chat/`。

| 关注点 | 现网文件 |
|---|---|
| 路由总表 | `src/index.ts` |
| 错误契约 | `src/errors.ts` |
| Browser WS 帧 | `src/ws/frames.ts`、`src/contract/commands.ts`、`src/contract/wire-frames.ts` |
| Bot Gateway 协议 | `src/contract/bot-gateway.ts`、`src/chat/bot-gateway-protocol.ts` |
| Bot Stream 协议 | `src/contract/bot-stream.ts` |
| JWT 规则 | `src/auth/jwt.ts` |
| Profile 解析 | `src/profile/resolve.ts` |
| S3 presign | `src/s3/presign.ts`、`src/s3/url.ts` |
| fanout 现状 | `src/do/channel-fanout/object.ts` |
| 事故史 | `docs/incidents/2026-07-01-do-alarm-spin-fanout-churn.md` |
| 设计基线 | `docs/superpowers/specs/2026-06-22-lilium-chat-backend-design.md` |
| 权威 contract | `docs/api-contract.md`（v2.31） |
| PG 归档 schema | `archive/migrations/*.sql`、`archive/src/consumer/replay-tables.ts` |
| archive 白名单 | `src/archive/payload.ts` |

## 附录 B：与 AGENTS.md 不变量的对应

| AGENTS.md 不变量 | Elixir 版落点 |
|---|---|
| 无跨 DO 2PC，durable outbox + alarm | 单库同事务；outbox 大减（仅 bot_deliveries 可选） |
| per-channel 单调 UUIDv7 event_id | `Channel.<id>` 进程内计数器 + PG 持久化 |
| WS 命令在 UserConnection（hibernation） | WS 命令在 socket 进程 + Channel 进程 |
| ChatChannel DO name = channel_id | PG `chat.channels.channel_id` PK |
| 幂等 `command_id` / `Idempotency-Key` ≡ `operation_id` | `chat.idempotency_keys` 同事务 |
| replay 重投影 | 读路径 join 当前 `messages.status` |
| message mutation channel-scoped | 路由 + 校验逻辑直译 |
| 附件 presign/finalize in UserDirectory | presign/finalize 路由 + PG `chat.attachments` |
| DO SQLite ↔ PG archive parity | PG 直接 primary，parity 概念消失（§4.3） |

---

*本文件为调研稿。若 go，建议另起 `docs/specs/2026-08-19-lilium-chat-elixir-redesign.md` 作为实现 spec，并拆 `docs/plans/` 分阶段计划。*
