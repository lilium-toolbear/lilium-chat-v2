# Lilium Chat Elixir 重写 — 实现 Spec

状态：实现 spec（基于调研稿 + 决策访谈收敛）
日期：2026-08-19
前置：[`2026-08-19-elixir-rewrite-research.md`](./2026-08-19-elixir-rewrite-research.md)（调研稿，可行性论证）
权威协议参考：[`docs/api-contract.md`](../../../lilium-chat/docs/api-contract.md)（旧 repo lilium-chat，v2.31，唯一 source of truth）
代码位置：**本 repo（lilium-chat-v2）**（Elixir 应用 + conformance harness）；**旧 repo（lilium-chat）保留作参考** + 差分测试的旧实现目标

---

## 0. 摘要

用 Elixir/Phoenix 重写 lilium-chat 后端，**单机部署**，**协议兼容 drop-in replace**。

**核心驱动**（访谈确认，主→次）：
1. **痛点 b（主）**：读路径便宜——消除"刷新页面 = N+5 次 DO 唤醒"的结构性 RPC 扇出。现网 `GET /bootstrap` 单次扇出 `1×UserDirectory + 1×ChannelDirectory + N×ChatChannel + 3×ChatChannel(active) + profile`，用户频道越多刷新越贵（per-DO billable duration）。单机后全部塌缩为**对同一 PG 实例的查询**。
2. **痛点 a（次）**：fanout 简化——lease/retry-queue/dead-letter/alarm 整套机制由 PubSub 广播 + 进程存活即在线替代。

**硬约束**：
- **全量 API parity**：contract v2.31，50 路由 + 3 WS 协议 + 68 错误码，drop-in（前端零改动）。**不砍 bot 域**。
- **单机、无 HA、冷切换、无回滚**；不预估时间。
- **PG 提升为 primary**：`chat_v2.*` schema（重新设计，简化"无跨 DO 事务"的妥协）。`public.users`（profile）与 `chat_v2` 同实例、不同 schema。

**go/no-go 闸门**：conformance 差分测试（旧 Worker vs 新 Elixir）+ 真实 S3 上传 E2E，Phase 0 先验证三个关键假设（conformance 机制、PubSub fanout、SigV4）。

---

## 1. 决策记录（shared understanding）

以下为访谈逐条确认的决策，是本 spec 的约束基线。

| # | 决策 | 结论 |
|---|------|------|
| D1 | 目标 | 主 = 读路径便宜（痛点 b）；次 = fanout 简化（痛点 a） |
| D2 | 范围 | **全量 parity**（含 bot 域），不砍 |
| D3 | 时间 | 不预估（不约束进度） |
| D4 | 存储 | **PG primary**；`chat_v2.*` **重新设计**（简化分布式妥协）；数据从 `chat.*`/SQLite 导入 |
| D5 | Cutover | **冷切换**，无回滚，单窗口 |
| D6 | 部署 | **单机**（gina，本地服务器，Cloudflared 对外），无 HA |
| D7 | Conformance | **先建**，作 go/no-go 闸门；差分测试 + 归一化 diff + 手写 scenario |
| D8 | membership_version | 收敛为**单一 SoT**（`channels.membership_version` + `events.membership_version_at_event`）；砍 per-user 投影 + lease 副本；门禁 = gate 时回查 `channel_members` |
| D9 | 限流 | **不实现**（保留 `RATE_LIMITED` 429 错误码作 contract 兼容，但从不抛——与现网一致） |
| D10 | dedup 表 | 3 张（`idempotency_keys`/`bot_effects_applied`/`stateful_session_effects_applied`）**合并一张** `idempotency` + Housekeeping GC |
| D11 | 跨 DO 幂等状态机 | **消失**（单 PG 事务 get-or-create） |
| D12 | `my_channels` 投影 | **拆解**为 `channel_members` + `read_state` + `channels`；bootstrap 一次 join |
| D13 | 写串行 | **per-channel GenServer**（进程内计数器 + 单写者 + PubSub 广播，crash 后从 PG `MAX(event_id)` 恢复） |
| D14 | bot delivery | **PG 表**（crash 恢复）+ 内存热路径 |
| D15 | 读路径验收 | 读严格只读（无隐藏写）；读打**同一 PG 实例**（`chat_v2.*` + `public.users`），查询数有界、零 per-channel 后端扇出；profile 直连（同库） |
| D16 | profile 缓存 | **直连**（同库 `public.users`，无跨服务跳，无 TTL 缓存） |
| D17 | 代码组织 | **新 repo**（Elixir + harness）；**旧 repo 不动，作参考** |
| D18 | 观测 | Sentry 目的地不变；Telemetry→Prometheus；JSON 结构化日志 |

**低杠杆默认假设**（未单独否决，视为确认）：Phoenix Channels 承载 3 条 WS；复用同一 `JWT_SECRET` / S3 凭证；CORS/Origin 白名单照抄；68 错误码 + 6 retryable + envelope + `X-Request-Id`(`req_<uuidv7>`) 照抄 `src/errors.ts`。

---

## 2. 目标架构

### 2.1 技术选型

| 层 | 选择 | 说明 |
|---|------|------|
| HTTP/WS | **Phoenix 1.7 + Bandit** | Phoenix Channels 承载 3 条 WS 协议（join/handle_info 贴合"命令→ack→事件"） |
| DB | **PostgreSQL**（现有实例）+ Ecto | `chat_v2.*`（业务）+ `public.users`（profile），同实例不同 schema |
| 内部消息 | **Phoenix.PubSub**（本地） | per-channel / per-user topic |
| JWT | `joken`（HS256） | 规则照抄 `src/auth/jwt.ts` |
| S3 SigV4 | `aws_signature_v4`（或自签） | 必须与现有 presign URL 兼容（§6.2） |
| 配置 | `config/runtime.exs` + 环境变量 | 对齐现有 `.dev.vars` 语义 |
| 观测 | Telemetry + Prometheus 端点 + Sentry | 对齐现有 Sentry OTLP 目的地 |
| 部署 | `mix release` 单二进制 + systemd | gina 单机；前置代理（Caddy/nginx）+ Cloudflared 对外 |

### 2.2 进程模型

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
│         - per-channel 单调 UUIDv7 event 计数器
│         - 提交后 PubSub broadcast("channel:<id>")
├── BotSupervisor (DynamicSupervisor)
│    └── Bot.<bot_id>           (per bot, lazy start)
│         - gateway 连接状态、delivery 热路径、offline policy
├── StreamSupervisor (DynamicSupervisor)
│    └── Stream.<channel_id>#<message_id>  (seq/ack buffer、finalize 幂等)
└── Housekeeping
     - idempotency GC（按 expires_at）
     - pending_attachments 过期
     - stream expiry
     - bot_deliveries 清理
```

要点：
- **Channel 进程**是 per-channel 顺序写的 owner（替代 ChatChannel DO 的"单 DO 内事务"角色），**不持有状态副本**——状态在 PG，进程只是串行化器 + 事件计数器 + 广播器。crash 重启后从 PG `MAX(event_id)` 恢复计数器。
- **socket 即订阅者**：BrowserWS socket join 后向 `channel:<id>` topic 订阅（membership 校验通过的所有 active 频道）；`session.live_start` 语义保留（wire 兼容），内部只是"订阅全部 active 频道"。
- **runtime 状态进程内存化**（易失）：stream seq/ack、active session refs、delivery 热路径、membership 缓存（ETS）。
- **持久状态在 PG**：`read_state`、`idempotency`、`bot_deliveries`（crash 恢复）。

### 2.3 部署

- **目标机器**：gina（本地服务器）。
- **对外**：Cloudflared 隧道，`chat.kuma.homes` 域名不变；前置代理（Caddy/nginx）路由到本机 Elixir 进程。
- **进程**：`mix release` 单二进制 + systemd 自动拉起。
- **回滚**：无（冷切换，窗口短，接受窗口内 in-flight 状态丢失/重放）。

---

## 3. 存储设计（`chat_v2.*`）

### 3.1 设计原则

- 以 `chat.*` 24 表为**基线**（已验证、数据已在 PG），但**简化"无跨 DO 事务 + 多 DO"的妥协**——单机单库后这些妥协不存在。
- **单库同事务**：outbox / alarm / lease 表整体消失。
- **只持久化需要持久化的状态**；runtime 状态进程内存化（§2.2）。
- 数据导入：`chat.*` 24 表 → `chat_v2.*`（近 1:1 拷贝）；DO SQLite runtime（如 `read_state`）经 debug API 导出。

### 3.2 表清单（`chat_v2` schema）

**核心域**（基线自 `chat.*`）：

| 表 | 来源 | 关键列 / 说明 |
|---|------|------|
| `channels` | `chat_channels`(channel_meta) | 含 **`membership_version`（SoT）**、`kind`、`status`、`member_count` |
| `channel_members` | `chat_channel_members`(members) | `user_id`、`role`、`status`、`joined_at`；**SoT 成员关系** |
| `messages` | `chat_messages` | 含 `status`（active/deleted/recalled）、`edited_at` |
| `message_edits` | `chat_message_edits` | 编辑历史 |
| `events` | `chat_events` | 含 **`membership_version_at_event`**（快照）、per-channel 单调 `event_id` |
| `attachments` | `chat_attachments` | S3 key、size、content_type、blurhash |
| `message_attachments` | `chat_message_attachments` | message↔attachment 关联 |
| `message_stickers` | `chat_message_stickers` | message↔sticker 关联 |
| `mentions` | `chat_mentions` | |
| `invites` | `chat_invites` | invite code → channel（**`invite_index` 投影可现算**） |
| `dm_pairs` | `chat_dm_pairs` | DM get-or-create 唯一约束 |
| `personal_stickers` | `chat_personal_stickers` | |
| `audit_logs` | `chat_audit_logs` | |
| `channel_pins` | `chat_channel_pins` | |
| `command_invocations` | `chat_command_invocations` | |
| `interactions` | `chat_interactions` | |
| `stateful_command_sessions` | `chat_stateful_command_sessions` | 含 `expires_at`、`effect_last_acked_seq` |
| `stateful_session_inputs` | `chat_stateful_session_inputs` | |

**Bot 域**（基线自 `chat.*`）：

| 表 | 来源 |
|---|------|
| `bot_apps` | `chat_bot_apps` |
| `bot_tokens` | `chat_bot_tokens`（SHA-256 hash，UNIQUE） |
| `bot_commands` | `chat_bot_commands` |
| `bot_command_aliases` | `chat_bot_command_aliases` |
| `bot_command_names` | `chat_bot_command_names` |
| `channel_command_bindings` | `chat_channel_command_bindings` |

**新增 runtime 表**（访谈决策）：

| 表 | 说明 |
|---|------|
| `read_state(user_id, channel_id, last_read_event_id, updated_at)` | 源自 `my_channels.last_read_event_id`（未读数）；**需从 DO SQLite 导出** |
| `idempotency(namespace, principal_kind, principal_id, operation, operation_id, channel_id, bot_id, client_effect_id, session_id, effect_seq, request_hash, response_json, expires_at)` | **3 张 dedup 表合并**；`namespace ∈ {user_command, bot_effect, session_effect}`；各 namespace 保留原 key 语义；Housekeeping 按 `expires_at` GC |
| `bot_deliveries(...)` | bot delivery crash 恢复（热路径走内存 mailbox） |

**不建 / 消失的表**（相对现网）：

| 现网表 | 处置 |
|---|------|
| `my_channels`（per-user 投影） | **拆解** → `channel_members` + `read_state` + `channels` |
| `membership_version` per-user 副本 / lease 副本 | **砍**（单一 SoT，§3.3） |
| `rate_buckets` | **不实现**（保留 429 码，不抛） |
| `idempotency_keys` / `bot_effects_applied` / `stateful_session_effects_applied` | **合并** → `idempotency` |
| `projection_outbox` / `archive_outbox` / `bot_delivery_outbox` / `fanout_queue` / `fanout_leases` / `fanout_events` / `online_sessions` / `live_sessions` / `live_user_channel_leases` / `alarm_jobs` / `archive_seq` / `event_seq` / `bot_connection_state` / `active_stateful_session_refs` / `stream_state` / `stream_due_jobs` / `message_stream_registry` / `bot_idempotency_keys` / `pending_attachments` / `public_channels` / `invite_index` | **消失**（outbox/lease/alarm 单库后无需；runtime 状态进程内存化；投影现算；`pending_attachments` 5min TTL 可接受丢失或补表） |

### 3.3 简化点（相对现网，逐条）

1. **membership_version 单一 SoT**：保留 `channels.membership_version`（SoT）+ `events.membership_version_at_event`（快照）；**砍** per-user `my_channels.membership_version` 投影 + lease 副本。socket 端 ETS 缓存 per-channel version，门禁 = `event.mv_at_event > cached` → 回查 `channel_members`（SoT）。`my_channels_changed` 触发集不变（join/leave/dissolve，**不含 role change**）。
2. **3 张 dedup 表合并**：`idempotency(namespace, key…, request_hash, response_json, expires_at)`；`namespace` 区分 user_command / bot_effect / session_effect；各保留原 key 语义（user: principal/operation/operation_id；bot: channel/bot/client_effect_id；session: session/effect_seq）；**补 GC**（现网 3 表均无 TTL、无 GC、无限增长）。
3. **跨 DO 幂等状态机消失**：`POST /channels` / `POST /dms` 单 PG 事务内 get-or-create + `idempotency` 表；DM 用 `dm_pairs` 唯一约束 + 事务。
4. **`my_channels` 拆解**：bootstrap 一次 join `channel_members` + `read_state` + `channels`，不再走 per-user 投影（直接兑现痛点 b）。
5. **限流不实现**：保留 `RATE_LIMITED` 429 错误码（contract 兼容），但从不抛（与现网一致——`rate_buckets` 表现网亦从未使用）。
6. **outbox/alarm/lease 消失**：单库同事务直写；bot delivery 仅保留 `bot_deliveries` 表作 crash 恢复。

### 3.4 索引（热读路径）

- `channel_members(user_id, status)` — bootstrap 列我的频道
- `messages(channel_id, event_id DESC)` — timeline 分页
- `events(channel_id, event_id)` — gap 恢复 / replay
- `read_state(user_id, channel_id)` — PK
- `idempotency(namespace, <key 列>, expires_at)` — 幂等查 + GC
- `bot_deliveries(bot_id, status)` — crash 恢复
- `channel_members(channel_id, status)` — 成员列表 / 门禁回查

---

## 4. 读路径设计（痛点 b）

**验收标准**（访谈确认，替代 CF 话术"零 DO 唤醒"）：
1. **读严格只读**——无隐藏写副作用（conformance 比对响应 + 代码审查验证）。
2. **读打同一 PG 实例**（`chat_v2.*` + `public.users`），查询数有界，**零 per-channel 后端扇出**（不 N 个独立后端、不 N 个连接）——telemetry 可测。
3. **profile 直连**（同库 `public.users`，batch 50，无跨服务跳、无 TTL 缓存）。

**对照现网**：`GET /bootstrap` 现网扇出 `1×UserDirectory + 1×ChannelDirectory + N×ChatChannel + 3×ChatChannel + profile`（N+5 次 DO 唤醒）。Elixir 版 = 对同一 PG 的若干查询（`channel_members` join `channels` join `read_state` + active channel 的 `messages`/`channel_pins`/`command_manifest`），无 per-channel 网络扇出。

**纯读不写**（现网已验证，core.ts:165-209 纯 SQL 读；outbox 写只在写路径 core.ts:222-508，alarm 驱动）——Elixir 读路径保持严格只读。

---

## 5. 写路径 / fanout

### 5.1 写串行 + 单调 event_id

per-channel GenServer（§2.2）：进程内计数器 + 单写者串行 + 提交后 PubSub 广播。crash 后从 PG `MAX(event_id)` 恢复。per-channel 单调 UUIDv7 `event_id` 语义保持（contract 不变量）。

### 5.2 fanout（PubSub）

```
Channel.<id> 进程：PG txn 提交（messages + events + idempotency）
  → Phoenix.PubSub.broadcast("channel:<id>", {event_frame})
    → 各 BrowserWS socket 进程收到 → 校验 membership_version（ETS 缓存）→ socket.send
  → 同时 broadcast("user:<uid>", {user_event}) 给 membership 变更受影响的用户
```

- **在线判定**：进程存活即在线（socket 进程退出即取消订阅）——lease/TTL 消失。
- **顺序**：Channel 进程串行提交 + PubSub 同 topic 保序。
- **多端**：每 socket 一个订阅（天然多端）。
- **失败处理**：无需 retry queue / dead-letter（contract 定义 best-effort；漏收走 HTTP gap 恢复）。
- **membership 门禁**：广播帧内携带 `membership_version_at_event`；socket 端 ETS 缓存本地 version 快速判定，不匹配则回查 `channel_members`（SoT）或走 HTTP resync。membership 变更事务提交后，向受影响用户 `user:<uid>` topic 广播 `my_channels_changed` hint（触发集 = join/leave/dissolve，不含 role change）。
- **stream live frames**：同 `channel:<id>` topic，live-only 语义不变（`stream_event` 帧）。

### 5.3 bot gateway 投递

`Bot.<bot_id>` 进程在线（socket 已连接）→ 直接投 mailbox；离线 → 按 contract offline policy（precheck `BOT_OFFLINE` / 已 commit 短 TTL / passive drop）。**已 commit 未投递的 invocation 落 `bot_deliveries` 表**（crash 恢复），bot 重连后按 `last_received_delivery_id` 续传（协议已支持）。替代 `bot_delivery_outbox` + alarm flush。

---

## 6. 鉴权 / 附件 / 错误契约

### 6.1 JWT / bot token

- **Browser**：ToolBear JWT（HS256，**同 `JWT_SECRET`**），规则照抄 `src/auth/jwt.ts`：`sub` 必填；`client_id` 存在 → `MACHINE_TOKEN_NOT_ALLOWED`；`managed_session=true` 或 `owner_user_id`/`effective_account_user_id` ≠ sub → `SESSION_NOT_ALLOWED`；`admin` claim。
- **Bot**：token 原文只返回一次，DB 存 SHA-256 hash（`bot_tokens`，UNIQUE）。

### 6.2 S3 SigV4（C7 关键风险点）

**隐蔽兼容点**（现网 `presign.ts:37` + `url.ts:22-25`）：
- **签名用含 bucket 的 path-style URL**（SigV4 canonical URI 要带 bucket），但**返回给浏览器的 PUT URL 把 bucket 前缀剥掉**（`s3BrowserUploadUrl`——gina 上 nginx 重新注入 bucket 前缀）。
- `Content-Type` + `Cache-Control` 要**进签名**（`allHeaders: true`）。
- 5min TTL（`PRESIGN_TTL_SECONDS = 300`）。
- Elixir 版必须"**带 bucket 签名、去 bucket 返回**"，否则浏览器 PUT 403。
- **验收**：真实 S3 上传 E2E（C7）。

### 6.3 错误契约 / CORS

- 68 错误码 + `HTTP_STATUS_BY_CODE` + 6 `RETRYABLE_CODES` + envelope `{error:{code,message,retryable}}` + `X-Request-Id`(`req_<uuidv7>`)——照抄 `src/errors.ts`。
- CORS / Origin 白名单（`lilium.kuma.homes` + localhost）照抄。

---

## 7. Conformance harness（go/no-go 闸门）

**核心思路**：把 `docs/api-contract.md` 变成可执行黑盒测试，对旧 Worker 和新 Elixir **双跑差分**。

### 7.1 差分测试

- 同一 **scenario 脚本**分别打：
  - (a) 旧 Worker——本地 `wrangler dev`（干净 miniflare state）
  - (b) 新 Elixir——干净 PG `chat_v2.*`
- 两边都从**空状态**开始、脚本确定性 → **脚本即 fixture**（无需互相灌数据）。
- 捕获全部 HTTP/WS 响应后 diff。

### 7.2 易变字段归一化

`request_id`、时间戳、服务端生成 UUID（message_id/event_id/attachment_id）两边必然不同。diff 前先**归一化**（替换为 `{{UUID}}`/`{{TS}}` 占位符）再比对，**而非白名单忽略**（更稳，不易漏字段）。

### 7.3 用例来源

- **手写 scenario**（go/no-go 闸门）：从 contract v2.31 + 133 个 vitest 边界用例提炼——幂等冲突、membership 门禁、replay 重投影、stream finalize 幂等、SigV4 presign。
- 之后可补**自动生成的广度覆盖**（contract 路由表 + 错误码表 + WS 帧定义 → 请求-响应对）。

### 7.4 增量建设

- **Phase 0**：scaffold + 代表子集（`GET /bootstrap` + `message.send` + 1 条 fanout + SigV4 E2E）作 go/no-go。
- 之后每个 phase 补齐对应用例。
- **验收门槛**（cutover 前）：conformance 全绿 + 差分 diff 空（除归一化字段）+ 真实 S3 上传 E2E 通过。

### 7.5 读路径观测断言

conformance 之外，加"**读路径无隐藏写 / 无扇出**"的观测断言（§4 验收标准）——telemetry 测读请求的 PG 查询数、确认无写。

---

## 8. Cutover 计划

**单窗口冷切换**（无回滚，不做持续 shadow；主验证靠本地 conformance 差分，prod 只读路由做一次性 sanity 对比）：

1. **T-1d**：Elixir 版以**只读**模式上线（同一 PG，读路径 shadow 对比响应，验证读路径 parity）。
2. **T-0（窗口开始）**：旧 Worker 冻结写路由 → 校验 `chat.*` watermark 追平 → delta 同步（`chat.*`→`chat_v2.*` + debug API 导出 DO SQLite runtime 如 `read_state`）→ 校验（watermark + 抽查读）。
3. **T-0+**：前置代理切到 Elixir（写路径开放）→ 浏览器 WS 重连（HTTP 权威恢复保证无数据丢失）→ bot 重连续传。
4. **观察 24–48h**：错误率、fanout 延迟、Sentry、`GET .../events` 恢复流量。

**窗口内风险**：
- in-flight 消息：WS 命令未 ack 的，客户端重连后按 contract 用同一 `command_id` 重试 → 幂等命中或重新提交（与现网断线重试语义一致）。
- bot delivery：已 commit 未投递的 invocation，bot 重连后按 `last_received_delivery_id` 续传。
- stream 中：in-flight 的 stream 按 abandon 语义收口（contract v2.25）。

**archive consumer Worker 退役**：cutover 后 Elixir 直写 PG，archive pipeline 无源可消费 → **下线 consumer Worker**，保留 `archive/scripts/*`（replay/backfill/derive-channels）作工具。

**数据迁移内容**：

| 数据 | 动作 |
|---|------|
| 24 张归档域表 | 已在 PG（`chat.*`）→ 拷贝到 `chat_v2.*`（近 1:1）；校验 watermark |
| `read_state`（`my_channels.last_read_event_id`） | **仅 DO SQLite**（未归档）→ debug API 导出 → `chat_v2.read_state` |
| `idempotency`（3 表） | 短命 TTL，可接受丢失；或一并导出 |
| `bot_deliveries` / fanout / lease / stream 状态 | 运行时，cutover 时丢弃（WS 重连恢复） |
| `public_channels` / `invite_index` | 读时从 `chat_v2.channels` / `chat_v2.invites` **现算**（不建投影表） |
| 附件二进制 | SeaweedFS（不变） |
| Bot 端 | 连 WS 的 bot 断开重连（协议支持续传） |

---

## 9. 代码组织

- **本 repo（lilium-chat-v2）**：Elixir 应用（`mix release`）+ conformance harness。
- **旧 repo（lilium-chat）**：不动，作参考——contract 文档（`docs/api-contract.md`）+ 旧 Worker（供差分测试 `wrangler dev`）。
- 本 repo 需本地引用旧 repo（clone/submodule/path）以跑 `wrangler dev` + 读 `docs/api-contract.md`。
- 本 spec 位于新 repo `docs/specs/`；旧 repo 保留 contract + 旧实现作参考。

---

## 10. 观测

| 项 | 方案 |
|---|------|
| 部署 | `mix release` 单二进制 + systemd；gina + Cloudflared；前置代理（Caddy/nginx）不变 |
| 备份 | PG `pg_dump` 每日 + WAL 归档（若已有）；附件在 SeaweedFS（不变） |
| 监控 | Telemetry → Prometheus 端点；关键指标：WS 连接数、per-topic 订阅数、PG 事务 p99、PubSub 广播延迟、stream 活跃数、idempotency 冲突率、**读路径 PG 查询数**（§4） |
| 告警 | 进程重启次数、PG 连接池耗尽、内存阈值 |
| Sentry | Elixir SDK 或 OTLP 直发（现有目的地 `sentry.kuma.homes/api/9/...`） |
| 调试 | 保留 `/internal/debug/*` 等价端点（DEBUG_TOKEN 门控），降低运维习惯切换成本 |
| 日志 | JSON 结构化日志 |

**不再需要的运维动作**：outbox dead-letter 清理、alarm spin 巡检、free tier rows 限额监控、两个 Worker 的独立部署。

---

## 11. 分阶段计划

以单人、熟悉 Elixir 为前提；每阶段含 conformance 用例补齐 + 编译 + 测试。**不预估时间**（D3）。

| 阶段 | 内容 |
|---|------|
| **Phase 0：Spike（go/no-go）** | Phoenix + Bandit + Ecto 骨架；`chat_v2.*` 连接；`GET /bootstrap` + `GET /channels/:id` 只读；JWT 鉴权；SigV4 presign 验证（C7）；conformance harness scaffold + 代表子集（bootstrap + `message.send` + 1 条 fanout）验证 PubSub 模型 |
| **Phase 1：读路径全量** | 全部 GET 路由（channels/messages/events/context/members/directory/invites preview/stickers/bots/commands）+ profile 解析 + 错误契约 + CORS/Origin |
| **Phase 2：写路径核心** | Channel 进程 + per-channel event 计数器 + 幂等（同事务）+ `message.send/edit/recall/delete` + `channel.mark_read` + fanout 广播 + membership 门禁 + replay 重投影 |
| **Phase 3：Channel/Member/Invite/DM** | channel CRUD、dissolve、join、owner-transfer、member 管理、invite、DM get-or-create、`system.notice` |
| **Phase 4：Upload/Sticker** | presign/finalize（images + avatars）、sticker 库、blurhash 透传、S3 HEAD 校验 |
| **Phase 5：Bot 域** | BotRegistry 等价（token/commands/manifest）、developer/admin bots API、command.invoke、interaction.submit、rich UI components、pin |
| **Phase 6：Bot Gateway + Stream WS** | `Bot.<bot_id>` 进程、delivery 队列、effects 路由、offline policy、stateful session、`Stream.<cid>#<mid>` 进程（seq/ack/finalize 幂等） |
| **Phase 7：Cutover** | 只读 shadow 期、read_state 导出、维护窗口切换、观察期、archive consumer 退役 |

**全量 parity**（D2）：Phase 5/6（bot 域）不可砍，cutover 前必须完成。

---

## 12. 验收标准

| # | 项 | 验收方式 |
|---|------|------|
| A1 | 域名 `chat.kuma.homes`、TLS、CORS、Origin 白名单 | 前端零改动 |
| A2 | 全部 HTTP 路由 wire shape（contract v2.31） | conformance 差分（§7） |
| A3 | 68 错误码 + HTTP status 映射 + envelope + `X-Request-Id` | conformance（`src/errors.ts` 参照） |
| A4 | Browser WS subprotocol 协商 + 全部帧（含 payload-bearing `command_ack`） | WS conformance |
| A5 | Bot Gateway（hello/ready、3 类 delivery、effects、`session.stop_requested`）+ Bot Stream（seq/ack、finalize 幂等、`ack_seq`/`received_seq` 分离） | WS conformance |
| A6 | JWT 规则边界（`MACHINE_TOKEN_NOT_ALLOWED` / `SESSION_NOT_ALLOWED` / `admin` claim） | 单测 + conformance |
| A7 | presign URL 可被现有前端直接 PUT 成功（SigV4 兼容） | 真实 S3 上传 E2E |
| A8 | 幂等语义（同 key 同 body 重放返回缓存 ack / 异 body `409 IDEMPOTENCY_CONFLICT` / 不扫 events） | conformance |
| A9 | per-channel event 单调 + `GET .../events` gap 恢复 + replay 重投影（deleted/recalled 安全投影） | conformance |
| A10 | profile 解析（`public.users` 直连，batch 50） | 集成测试 |
| A11 | 数据：cutover 后 bootstrap / messages / events 与旧实现一致 | conformance 差分（§7） |
| A12 | **读路径便宜**（痛点 b）：读严格只读、打同一 PG 实例、零 per-channel 后端扇出 | telemetry + 代码审查（§4） |
| A13 | 观测：Sentry 事件、request id、关键指标可查 | 运维验收 |

**总验收门槛**：conformance 全绿 + 差分 diff 空（除归一化字段）+ 真实 S3 上传 E2E 通过 + 读路径观测达标。

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
| 无跨 DO 2PC，durable outbox + alarm | 单库同事务；outbox 消失（仅 `bot_deliveries` crash 恢复） |
| per-channel 单调 UUIDv7 event_id | `Channel.<id>` 进程内计数器 + PG 持久化 |
| WS 命令在 UserConnection（hibernation） | WS 命令在 socket 进程 + Channel 进程 |
| ChatChannel DO name = channel_id | PG `chat_v2.channels` PK |
| 幂等 `command_id` / `Idempotency-Key` ≡ `operation_id` | `chat_v2.idempotency` 同事务 |
| replay 重投影 | 读路径 join 当前 `messages.status` |
| message mutation channel-scoped | 路由 + 校验逻辑直译 |
| 附件 presign/finalize in UserDirectory | presign/finalize 路由 + PG `chat_v2.attachments` |
| DO SQLite ↔ PG archive parity | PG 直接 primary，parity 概念消失（§3） |

---

*本文件为实现 spec。实现启动后，按 §11 分阶段推进；每阶段以 §12 验收标准 + conformance 差分为闸门。*
