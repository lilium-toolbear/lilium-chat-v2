# ToolBear Chat Browser/Bot API Contract

状态：最终 API contract（v2.31，v4.4-aligned）
范围：lilium-chat 后端（Cloudflare Worker + Durable Object）的 browser/bot-facing wire shape
权威来源：

- **本文件**（`docs/api-contract.md`）是 Browser/Bot API contract 的 **唯一 source of truth**
- 实现设计：`docs/superpowers/specs/2026-06-22-lilium-chat-backend-design.md`（v4.0）
- Bot streaming / internal API spec：`docs/superpowers/specs/2026-06-30-lilium-chat-bot-streaming-and-internal-api-spec.md`

本文件只描述**最终 API 状态**，不含修订历史。前端与 bot 实现**以本文件为准**；任何 API 变更直接修改本文件，**不要**为追平 spec 去改历史 addendum、phase plan、gap tracker 等归档文档。

## 1. 边界

ToolBear 前端只调用 `/api/chat/*` Browser API。该路径由 Cloudflare Worker 承载在 `chat.kuma.homes`，ToolBear Python 后端不存储聊天消息，不代理聊天主路径，不读写聊天数据表。前端在 `lilium.kuma.homes`，**跨域**调用 `chat.kuma.homes`（CORS + WebSocket Origin 校验）。

聊天 backend 使用 Cloudflare Worker + Durable Object。附件二进制存储在 SeaweedFS（`s3.kuma.homes`，S3 兼容）；后端只存 attachment metadata 和归属关系。Worker 直接验证现有 ToolBear browser JWT，得到当前 `user_id`。用户 profile 不写入后端存储：display name 和 avatar 由 Worker 按 `user_id` 调用只读数据源（ToolBear 生产 Postgres 的 `users` 表，经 Hyperdrive）补齐。

第一版前端可以先只接 `GET /api/chat/bootstrap` 渲染页面。发送消息、WebSocket、附件上传和成员管理必须按本文 contract 预留，不在前端发明第二套形状。

### 1.1 路由总览

| 方法 | 路径 | 说明 | 章节 |
|---|---|---|---|
| GET | `/api/chat/bootstrap` | 首屏聚合 | §4.1 |
| GET | `/api/chat/channels` | 频道列表 | §5.1 |
| GET | `/api/chat/channels/{channel_id}` | 频道详情 | §5.2 |
| PATCH | `/api/chat/channels/{channel_id}` | 更新频道信息 | §5.3 |
| POST | `/api/chat/channels` | 创建频道 | §5.2b |
| POST | `/api/chat/dms` | get-or-create 一对一 DM | §5.2c |
| POST | `/api/chat/channels/{channel_id}/dissolve` | 解散群聊 | §5.4 |
| GET | `/api/chat/channels/directory` | 公开频道目录 | §5.6 |
| POST | `/api/chat/channels/{channel_id}/join` | 加入公开频道 | §5.7 |
| POST | `/api/chat/channels/{channel_id}/invites` | 创建邀请 | §5.8 |
| GET | `/api/chat/invites/{invite_code}` | 邀请预览（read-only，无 join 副作用） | §5.10 |
| POST | `/api/chat/invites/{invite_code}/accept` | 接受邀请 | §5.9 |
| POST | `/api/chat/channels/{channel_id}/owner-transfer` | 转让群主（原子） | §7.5 |
| GET | `/api/chat/channels/{channel_id}/messages` | 历史消息分页 | §6.1 |
| GET | `/api/chat/channels/{channel_id}/events` | 频道事件 gap 恢复（HTTP 权威） | §6.1b |
| GET | `/api/chat/events` | 全局事件回放（per-channel cursor map） | §10.3 |
| GET | `/api/chat/channels/{channel_id}/messages/{message_id}/context` | 消息上下文 | §6.6 |
| GET | `/api/chat/channels/{channel_id}/members` | 成员列表（模糊搜索） | §7.1 |
| GET | `/api/chat/channels/{channel_id}/members/{user_id}` | 按用户 ID 精确读单成员 | §7.1b |
| POST | `/api/chat/channels/{channel_id}/members` | 添加成员 | §7.2 |
| PATCH | `/api/chat/channels/{channel_id}/members/{user_id}` | 修改成员角色 | §7.3 |
| DELETE | `/api/chat/channels/{channel_id}/members/{user_id}` | 移除成员 / 离开频道 | §7.4 |
| POST | `/api/chat/uploads/images/presign` | 创建图片上传 | §8.1 |
| POST | `/api/chat/uploads/images/{attachment_id}/finalize` | 完成图片上传 | §8.2 |
| GET | `/api/chat/stickers` | 个人表情库列表 | §8.3 |
| POST | `/api/chat/stickers` | 保存个人表情 | §8.3 |
| DELETE | `/api/chat/stickers/{sticker_id}` | 删除个人表情 | §8.3 |
| WS | `message.send` / `message.edit` / `message.recall` / `message.delete` | 消息生命周期 mutation | §6.2 / §6.3 / §6.4 / §6.5 |
| WS | `channel.mark_read` | 标记已读 | §5.5 |
| WS | `session.live_start` | 启动全频道 live fanout（无 replay） | §5.11 |
| WS | `session.heartbeat` | 刷新 live session fanout lease | §5.12 |
| GET | `/api/chat/bot/ws` | Bot Gateway WebSocket RPC（bot token，outbound WS） | §9.7 |
| GET | `/api/chat/bot/channels/{channel_id}/streams/{message_id}/ws` | Bot Stream WebSocket（一连接一流；append/finalize） | §9.15 |
| PUT | `/api/chat/bot/commands` | Bot 注册全局 slash command catalog（bot token） | §9.3 |
| WS (Bot Gateway) | `delivery_result` / `session.effects` | Bot 非流式 effect + `start_stream`（append/finalize 走 Stream WS） | §9.7 / §9.13 |
| WS (Bot Stream) | `append` / `finalize` | 单条 streaming message 的 delta 追加与 finalize | §9.15 |
| PATCH | `/api/chat/channels/{channel_id}/commands/{bot_command_id}` | allow/block 频道 command binding（Browser admin） | §9.3 |
| GET | `/api/chat/channels/{channel_id}/commands` | 频道 command manifest | §9.4 |
| GET | `/api/chat/commands/directory` | 全局 command 目录搜索 | §9.12 |
| WS | `channel.pin_message` / `channel.unpin_message` | owner/admin 置顶 / 取消置顶 timeline 消息 | §6.7 |
| POST | `/api/chat/bots` | 创建 bot（developer） | §9.10 |
| GET | `/api/chat/bots` | 列出当前用户拥有的 bot | §9.10 |
| GET | `/api/chat/bots/{bot_id}` | bot 详情（owner） | §9.10 |
| PATCH | `/api/chat/bots/{bot_id}` | 更新 bot（owner；`official` 需 admin） | §9.10 |
| GET | `/api/chat/bots/{bot_id}/tokens` | 列出 token 元数据 | §9.10 |
| POST | `/api/chat/bots/{bot_id}/tokens` | 创建 token | §9.10 |
| DELETE | `/api/chat/bots/{bot_id}/tokens/{token_id}` | 撤销 token | §9.10 |
| GET | `/api/chat/admin/bots` | 全局 bot 列表（admin） | §9.11 |
| GET | `/api/chat/admin/bots/{bot_id}` | bot 详情（admin） | §9.11 |
| PATCH | `/api/chat/admin/bots/{bot_id}` | 更新任意 bot（admin） | §9.11 |
| GET | `/api/chat/admin/bots/{bot_id}/tokens` | 列出 token 元数据（admin） | §9.11 |
| DELETE | `/api/chat/admin/bots/{bot_id}/tokens/{token_id}` | 撤销 token（admin） | §9.11 |
| POST | `/api/chat/bot/channels/{channel_id}/uploads/images/presign` | Bot 图片上传 presign（channel-scoped） | §9.17 |
| POST | `/api/chat/bot/channels/{channel_id}/uploads/images/{attachment_id}/finalize` | Bot 图片上传 finalize | §9.17 |
| WS | `command.invoke` / `interaction.submit` | slash command 调用 / rich UI interaction 提交（`message_id` 或 `pin_id` locator；路由到 ChatChannel DO → Bot Gateway delivery 或平台短路） | §9.5 / §9.6 |
| WS (Bot Gateway) | `session.stop_requested` / `session.close` | graceful stop 请求 / Bot 收尾关闭 stateful session | §9.7.4 |

`message.*` 与 `channel.mark_read` 为 WS command（channel-scoped，路由到 `ChatChannel DO`）。其余 HTTP 端点中，`/api/chat/invites/{invite_code}*` 不含 `channel_id`，服务端按 `invite_code` 路由，索引 lag 窗口返回 `409 ROUTE_INDEX_PENDING`。

## 2. 通用约定

### 2.1 认证

Browser API 使用现有 ToolBear browser JWT。Worker 直接验证 JWT：

```http
Authorization: Bearer <toolbear_browser_jwt>
```

Worker 验证：

- JWT 签名有效（HS256）。
- `exp` 未过期。
- subject 对应现有 ToolBear user UUID。
- token type 是 browser user session。
- machine token（带 `client_id`）拒绝。
- delegated / managed session 拒绝：`managed_session=true`，或 `owner_user_id != sub`，或 `effective_account_user_id != sub`（任一即拒）。
- ToolBear admin claim：JWT payload `admin === true` 时 Worker 将 caller 视为 chat admin（`is_admin`），用于 `visibility: "official"` 设置及 `GET/PATCH /api/chat/admin/bots*` 鉴权。非 admin JWT 不得通过 developer API 将 bot `visibility` 设为 `official`（`403 ADMIN_ACCESS_REQUIRED`）。

拒绝 delegated / managed session 的错误码固定为：

```json
{
  "error": {
    "code": "SESSION_NOT_ALLOWED",
    "message": "Chat requires a direct user session",
    "retryable": false
  },
  "request_id": "req_..."
}
```

WebSocket 连接不能设置 `Authorization` header。前端必须用 WebSocket subprotocol 传递同一个 browser JWT：

```js
new WebSocket("wss://chat.kuma.homes/api/chat/ws", [
  "lilium.chat.v2",
  "bearer.<toolbear_browser_jwt>"
])
```

Worker 只接受 `lilium.chat.v2` + `bearer.<jwt>` subprotocol（旧协议 `lilium.chat.v1` 已废弃，connect 返回 `426` 或握手失败）。JWT 验证规则与 HTTP Browser API 一致。WS upgrade 时校验 `Origin` ∈ {`https://lilium.kuma.homes`, 本地开发 origin}，不匹配拒绝。

> connect URL 不使用 `?cursors=`。旧客户端若传入，服务端 **MAY ignore**，但 **MUST NOT** 用于 `UserConnection` replay。Per-channel gap recovery 由 HTTP `GET /api/chat/bootstrap`、`GET /api/chat/channels/{channel_id}/events` 或 `GET /api/chat/channels/{channel_id}/messages` 承担。Live push 在 WS `open` 后由客户端自动发送 `session.live_start` 建立（§5.11）。

### 2.2 ID

ID 是不透明字符串。前端不得解析 ID。

规则：

- 用户 ID 使用现有 ToolBear user UUID 字符串。
- 频道、消息、附件、Bot、command、invocation、event ID 使用聊天后端定义的 UUIDv7 字符串。
- event_id 是 per-channel 单调 UUIDv7（同频道内严格单调，跨频道顺序任意）。
- API contract 只要求这些 ID 作为 opaque string 传输；前端不得解析、拼接、校验前缀或从前缀推断类型。对 event_id 做字符串字典序比较是允许的（单调 UUIDv7 字典序 = 时间序）。

### 2.3 时间

所有时间字段使用 ISO 8601 UTC 字符串：

```json
"2026-06-21T05:30:00Z"
```

前端负责按浏览器本地时区显示。

### 2.4 分页

列表接口使用 cursor：

```text
?limit=50&cursor=opaque-cursor
```

响应：

```json
{
  "items": [],
  "next_cursor": "opaque-cursor"
}
```

`next_cursor: null` 表示没有下一页。

### 2.5 幂等
All mutating operations use a client-generated durable operation id. HTTP carries it in the `Idempotency-Key` header; WS carries it in the top-level `command_id` field. `Idempotency-Key` and `command_id` are the same semantic layer; they differ only by transport.

Rules: client generates the operation id before sending; retrying the same operation reuses it; a new operation uses a new id; same id + same body → same committed result; same id + different body → `IDEMPOTENCY_CONFLICT`; scoped by `(principal_kind, principal_id, operation, operation_id)`; service stores `request_hash` + `response_json` with the business mutation in the same target DO transaction.

Internal mapping: `HTTP Idempotency-Key -> operation_id`; `WS command_id -> operation_id`.

幂等缓存存储完整 ack payload：对所有 idempotent message mutation，`idempotency_keys.response_json`（`operation_id`-keyed）必须存**完整 committed ack payload**，不只存 ID。重复重试（同 `operation_id` + 同 `request_hash`）原样返回该缓存 ack payload。若事后 profile display 数据变更，重复重试仍可能返回旧的 `display_name`/`avatar_url`——可接受（idempotency replay 优先稳定提交结果；正常 history/event replay 按既有策略实时 resolve 新 profile）。

Conflict (WS):
```json
{
  "frame_type": "command_error",
  "command_id": "01JBBB...",
  "error": { "code": "IDEMPOTENCY_CONFLICT", "message": "idempotency key reused with different request body", "retryable": false }
}
```
HTTP conflict returns the error envelope with HTTP 409.

> **delta（v2.31）**：`IDEMPOTENCY_CONFLICT` 的 `message` 文案在本契约与 v2 实现中**统一**为 `idempotency key reused with different request body`（所有 operation 一致）。旧 Worker 因 operation 而异：`message.send` → `command_id reused with different body`；`channel.create` / `dm.open` / `members.add` / `members.role` / `members.remove` → `idempotency_key reused with different body`；channel pin / `sticker.save` / `sticker.delete` / `interaction.submit` 等 → `operation_id reused with different body`；presign/finalize → `Idempotency-Key reused with different body`。客户端以 `code` 为准，不依赖 message 文案；conformance 差分对 `message` 归一化（#27）。

`command_id` is generated by the client and is the WebSocket transport form of the same durable operation id represented by HTTP `Idempotency-Key`. For WS commands, `command_id` is not merely an ack correlation id — it is also the idempotency key. For HTTP mutations, the equivalent field is `Idempotency-Key`. Do not introduce payload-level duplicate operation ids (`client_message_id` / `client_mutation_id` / `client_invocation_id` / `client_interaction_id`).

### 2.6 错误 envelope

所有错误返回：

```json
{
  "error": {
    "code": "FORBIDDEN",
    "message": "not a channel member",
    "retryable": false
  },
  "request_id": "req_..."
}
```

`code` 是稳定机器码，`message` 是给前端和日志看的英文短句。每个 HTTP 响应带 `X-Request-Id` 头。

本 contract 不定义通用 `NOT_FOUND`。Browser client 必须识别资源级 not-found code：`CHANNEL_NOT_FOUND`、`MESSAGE_NOT_FOUND`、`MEMBER_NOT_FOUND`、`INVITE_NOT_FOUND`。

### 2.7 Mutation 与事件边界

高频实时写操作使用 WebSocket command frame。WebSocket 同时承载两类 frame：

- `command`：浏览器发给 Worker 的请求。
- `event`：Worker 已经接受并写入后端后广播出来的事实。

规则：

- 用户发送消息、调用 slash command、点击 Bot component 都是 command request，不是 event。
- command request 带 `command_id`（既是 ack 关联，也是 durable 幂等键，见 §2.5）。
- Worker 写入后端后产生 `message.created`、`command.invoked`、`interaction.created` 等事件。
- WebSocket 向频道订阅者广播这些事件。
- 当前用户也通过同一条事件流确认最终状态。

HTTP API 保留给首屏 bootstrap、历史分页、频道/成员管理、附件上传、公开目录、邀请、事件回放。实时消息发送、slash command invocation、Bot rich UI interaction 不走 HTTP mutation。

## 3. 数据对象

### MessageLocator

Browser-facing message references must use:
```json
{ "channel_id": "...", "message_id": "..." }
```
`message_id` alone is not a valid Browser API locator. Applies to: timeline operations; edit/recall/delete; reply targets; notification deep links; search result deep links; message context loading.

### 3.1 UserSummary

用户展示必须包含 display name 和 avatar。`avatar_url` 可以为 `null`，前端使用标准 fallback。**`display_name` 类型为 `string`（非 null）**。

后端只在持久化层内保存 `user_id`。返回 `UserSummary` 前，Worker 只读 ToolBear `users` 表批量解析 `user_id`。display name 不可为空（如解析不到，使用 fallback 显示名（形如 `user-<前8位>`），**不展示裸 user_id 作为主身份**）。

```json
{
  "user_id": "00000000-0000-7000-8000-000000000101",
  "display_name": "alice",
  "avatar_url": "https://example.com/avatar.png"
}
```

### 3.2 ChannelSummary

```json
{
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "kind": "channel",
  "visibility": "private",
  "title": "克利夫兰先导报",
  "avatar_url": "https://example.com/channel.png",
  "member_count": 11,
  "role": "member",
  "status": "active",
  "unread_count": 3,
  "last_read_event_id": "01J...",
  "last_message_preview": "Zemo: 我也不行",
  "last_message_at": "2026-06-21T05:24:00Z",
  "last_event_id": "01J..."
}
```

`last_event_id` 是该频道最后事件的 per-channel 单调 UUIDv7，用于 per-channel cursor。`last_read_event_id` 同样 per-channel。

枚举：

- `kind`: `channel` | `dm`
- `visibility`: `private` | `public_unlisted` | `public_listed`
- `role`: `owner` | `admin` | `member`
- `status`: `active` | `archived` | `dissolved`

### 3.3 ChannelDetail

```json
{
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "kind": "channel",
  "visibility": "private",
  "title": "克利夫兰先导报",
  "topic": "频道说明",
  "avatar_url": "https://example.com/channel.png",
  "member_count": 11,
  "role": "member",
  "status": "active",
  "created_at": "2026-06-20T12:00:00Z",
  "updated_at": "2026-06-21T05:00:00Z"
}
```

### 3.4 Message

```json
{
  "message_id": "00000000-0000-7000-8000-000000000301",
  "command_id": "00000000-0000-7000-8000-000000000401",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "sender": {
    "kind": "user",
    "user": {
      "user_id": "00000000-0000-7000-8000-000000000101",
      "display_name": "Zemo",
      "avatar_url": null
    }
  },
  "type": "text",
  "format": "plain",
  "status": "normal",
  "stream_state": "none",
  "text": "多探索搜装备吧",
  "reply_to": null,
  "reply_snapshot": null,
  "attachments": [],
  "components": [],
  "mentions": [],
  "created_at": "2026-06-21T05:30:00Z",
  "updated_at": "2026-06-21T05:30:00Z",
  "edited_at": null,
  "deleted_at": null,
  "recalled_at": null
}
```

枚举：

- `type`: `text` | `image` | `sticker` | `system`
- `format`: `plain` | `markdown` | `unsafe-markdown`
  - **用户消息**：仅 `plain`。
  - **Bot 消息**：`plain` | `markdown` | `unsafe-markdown`（`unsafe-markdown` 写入限制见 §3.9.1）。
  - Browser 渲染规则见 **§3.9**。
- `status`: `normal` | `edited` | `deleted` | `recalled` | `failed`（bot stream 中断 partial only）
- `stream_state`: `none` | `streaming` | `final` | `abandoned`

Bot stream **正常完成**：`stream_state=final`、`status=normal`；**`components=[]`**（stream 路径禁止 components，见 §3.8）。Bot stream **中断保留 partial**：`stream_state=abandoned`、`status=failed`；**不是**正常完成回答，前端须与 final bot reply 视觉区分。Abandoned partial **`components=[]`**；**不**附带 `attachment_ids`（stream finalize 当前不启用 attachment，见 §9.15.4）。

非 stream Bot 消息（`send_message` / `update_message`）使用 **`stream_state=none`**，可携带 `components`（§3.8）。

`command_id` 是发送方在 `message.send` 时提供的 durable operation id（见 §2.5），用于 optimistic UI 关联与调试。由客户端生成，作为 operation id 处理，不是服务端 message id。

`sticker` 字段：非 sticker 消息 `sticker` 为 `null`；sticker 消息 `sticker` 为完整投影。在上方 base 投影中省略该字段，下方单独给出 sticker 消息投影。

Sticker 消息投影：

```json
{
  "message_id": "00000000-0000-7000-8000-000000000301",
  "command_id": "00000000-0000-7000-8000-000000000411",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "sender": {},
  "type": "sticker",
  "format": "plain",
  "status": "normal",
  "stream_state": "none",
  "text": null,
  "sticker": {
    "sticker_id": "00000000-0000-7000-8000-000000000901",
    "attachment_id": "00000000-0000-7000-8000-000000000501",
    "url": "https://s3.kuma.homes/lilium-chat-attachments/chat/00000000-0000-7000-8000-000000000501",
    "mime_type": "image/png",
    "width": 512,
    "height": 512,
    "size_bytes": 12345,
    "blurhash": "LFE.~f_3%D%M01V@kWM{Rj%Mt7WBt7WB"
  },
  "reply_to": null,
  "reply_snapshot": null,
  "attachments": [],
  "components": [],
  "mentions": [],
  "created_at": "2026-06-25T00:00:00Z",
  "updated_at": "2026-06-25T00:00:00Z",
  "edited_at": null,
  "deleted_at": null,
  "recalled_at": null
}
```

Sticker 消息投影规则：

- `type="sticker"` 要求 `sticker != null`。
- `sticker.attachment_id` 是可复用的 canonical image id（跨用户共享）。
- `sticker.sticker_id` 是发送方在发送时的个人表情库 item id，**不属于接收方**；接收方不得假设 `sticker.sticker_id` 属于自己。
- 接收方把该 sticker 存入自己的表情库时，用 `sticker.attachment_id` + 当前 `channel_id`，**不**用 `sticker.sticker_id`，也**不**用 `message_id`。
- `attachments=[]` 以避免重复渲染图片。
- `text=null`、`format="plain"`、`components=[]`、`mentions=[]`。

Deleted/recalled sticker 投影（不泄露原图）：

```json
{
  "type": "sticker",
  "status": "deleted",
  "text": null,
  "sticker": null,
  "attachments": [],
  "components": [],
  "mentions": []
}
```

删除和撤回消息保留同一个 `message_id` 供审计和事件状态更新使用。Browser history 和 event replay 返回的是可见投影，不返回已删除/撤回消息的原始 `text`、`sticker`、`attachments`、`components`、`mentions`（sticker 投影同样清空）。

历史分页中的已删除/撤回消息处理规则：

- `GET /api/chat/channels/{channel_id}/messages` 不返回 `status=deleted` 或 `status=recalled` 的消息项。
- `ReplySnapshot` 引用已删除/撤回消息时，只返回 `message_id` 和 `status`，`text_preview` 为空字符串。
- 管理员审计读取原始内容使用单独审计 API，不属于 Browser API。

### 3.5 ReplySnapshot

```json
{
  "message_id": "00000000-0000-7000-8000-000000000301",
  "sender_display_name": "alice",
  "text_preview": "上一条消息摘要",
  "status": "normal"
}
```

发送回复消息时，服务端在同一操作内生成 snapshot 存储并随消息返回。replay/history 投影时根据被引用消息当前 status 决定是否清空 `text_preview`。

**reply 目标是 image/sticker（v2.31）**：`text_preview` 为**空字符串**（不输出 `[图片]`/`[表情]` 占位文案）。v2.31 **不输出非 null** `media_preview`（存储快照不含该字段；目标被删除/撤回时投影保留 `media_preview: null` 键，与旧 Worker 一致）。旧 Worker 对 image/sticker 目标会输出非 null `media_preview{kind,url,blurhash,width,height}` 并据此清空 `text_preview` —— 记录为 delta，#27 差分归一处理。

### 3.6 Attachment

```json
{
  "attachment_id": "00000000-0000-7000-8000-000000000501",
  "kind": "image",
  "filename": "image.png",
  "mime_type": "image/png",
  "size_bytes": 12345,
  "width": 512,
  "height": 512,
  "url": "https://s3.kuma.homes/lilium-chat-attachments/chat/00000000-0000-7000-8000-000000000501"
}
```

第一版只允许 `kind=image`。`url` 是长期公开 URL，public read，不需签名。对象存储 key 不暴露给前端（`url` 路径只含高熵 `attachment_id`，不含 filename/user/channel）。

**风险登记**：private 频道附件也使用公开 URL。这是显式产品决策。缓解：storage key 高熵（`chat/{attachment_id}`，不可猜）；filename 仅在 JSON 返回、前端须转义；deleted/recalled 消息不再通过 Browser API 返回附件 URL（对象是否保留用于审计另定）；`url` 保持为字段，未来切 signed GET/proxy 可迁移。

### 3.7 Mention

```json
{
  "user_id": "00000000-0000-7000-8000-000000000101",
  "start": 6,
  "end": 12
}
```

`start` 和 `end` 使用 JavaScript string index。一条消息内同一用户可在多个不同 range 被 mention。

### 3.8 MessageComponent

Bot 消息可以携带 rich interactive UI。组件由 Bot 生成，Worker 校验后随消息持久化。普通用户消息不能携带 components。

**Components 与 streaming 互斥：**

- `MessageComponent` **仅**允许出现在 **非 stream** 的 Bot 消息上：经 `send_message` 或 `update_message` 写入的 canonical 消息，Browser 投影 **`stream_state=none`**。
- Bot **streaming** 路径（`start_stream` → Stream WS `append` / `finalize`；`stream_state` 为 `streaming` | `final` | `abandoned`）**不得**携带、持久化或向 Browser 投影非空 `components`。Stream 消息正文仅为 `text`（`format=plain` | `markdown` | `unsafe-markdown`，`unsafe-markdown` 写入限制同 §3.9.1）。
- 需要「流式正文 + Rich UI」时，Bot **必须**拆成两条消息：先完成 stream（`start_stream` … `finalize`），再 `send_message`（或 `update_message`）发送带 `components` 的独立非 stream 消息。
- Worker 校验：`start_stream` effect body 含非空 `components` → `422 BOT_EFFECT_INVALID`；Stream WS `finalize` 含非空 `components` → `stream_error` `BOT_EFFECT_INVALID`。Persisted stream 消息（含 finalized / abandoned partial）投影 **`components=[]`**。
- Browser：**仅**当 `stream_state=none` 且 `components.length > 0` 时渲染 Rich UI；`streaming` / `final` / `abandoned` stream 消息**不**渲染 components（wire 若出现非空数组亦忽略）。

**公共字段（所有 kind）：**

| 字段 | 说明 |
|---|---|
| `component_id` | UUIDv7；组件稳定 id |
| `kind` | 见下方枚举 |
| `custom_id` | Bot 私有 payload；前端只原样回传，不解析 |
| `disabled` | `true` 时不可提交 |
| `interaction_policy` | 可选；缺省 `multi` |
| `target_user_id` | `interaction_policy=targeted` 时必填；仅该用户可提交 |

**`interaction_policy`（Worker 在 `interaction.submit` 事务内原子执行）：**

| policy | 平台保证 |
|---|---|
| `multi`（默认） | 频道内任意可见成员可提交；同一 `(user, command_id)` 幂等 |
| `per_user_once` | 同一 `(message_id, component_id, actor_user_id)` 只允许一条成功 interaction；重复 → `409 INTERACTION_ALREADY_SUBMITTED` |
| `exclusive` | 全频道该 component 只允许一条成功 interaction；首个成功 submit **同事务** 将该 component 标 `disabled=true`；后续 → `409 COMPONENT_ALREADY_USED` |
| `targeted` | 仅 `target_user_id` 可提交；他人 → `403 INTERACTION_FORBIDDEN_TARGET` |

平台负责 **结构性门禁**（谁能点、能点几次、是否一次性锁死）与 **有序事件流**；**业务冲突**（余额、库存、游戏状态等）由 Bot 在 `delivery_result.effects` 中自行裁决。Bot 的 `disable_components` 用于 UI 反馈与 Bot 主动锁控件，**不能**作为 `exclusive` 的替代（`exclusive` 已在 submit 事务内锁死，无竞态窗口）。

按钮：

```json
{
  "component_id": "00000000-0000-7000-8000-000000000a01",
  "kind": "button",
  "style": "primary",
  "label": "确认",
  "custom_id": "confirm",
  "disabled": false,
  "interaction_policy": "exclusive"
}
```

下拉选择（`select`）：

```json
{
  "component_id": "00000000-0000-7000-8000-000000000a02",
  "kind": "select",
  "label": "选择装备",
  "custom_id": "pick_item",
  "disabled": false,
  "options": [
    { "value": "sword", "label": "长剑" }
  ]
}
```

可见单选（`radio`；与 `select` 区别为平铺选项，点一项即提交）：

```json
{
  "component_id": "00000000-0000-7000-8000-000000000a03",
  "kind": "radio",
  "label": "选择难度",
  "custom_id": "difficulty",
  "disabled": false,
  "options": [
    { "value": "easy", "label": "简单" },
    { "value": "hard", "label": "困难" }
  ]
}
```

单项复选（`checkbox`）：

```json
{
  "component_id": "00000000-0000-7000-8000-000000000a04",
  "kind": "checkbox",
  "label": "同意条款",
  "custom_id": "agree_tos",
  "disabled": false,
  "default_checked": false
}
```

多项复选（`checkbox_group`；须用户点组内「提交」才发 `interaction.submit`）：

```json
{
  "component_id": "00000000-0000-7000-8000-000000000a05",
  "kind": "checkbox_group",
  "label": "战利品筛选",
  "custom_id": "loot_filter",
  "disabled": false,
  "submit_label": "确认",
  "options": [
    { "value": "weapon", "label": "武器" },
    { "value": "armor", "label": "防具" }
  ],
  "min_selected": 0,
  "max_selected": 2
}
```

文本输入（`text_input`）：

```json
{
  "component_id": "00000000-0000-7000-8000-000000000a06",
  "kind": "text_input",
  "label": "角色名",
  "custom_id": "char_name",
  "disabled": false,
  "placeholder": "最多 16 字",
  "multiline": false,
  "min_length": 1,
  "max_length": 16,
  "submit_label": "提交"
}
```

枚举：

- `kind`: `button` | `select` | `radio` | `checkbox` | `checkbox_group` | `text_input`
- `style`（仅 `button`）: `primary` | `secondary` | `danger`
- `interaction_policy`: `multi` | `per_user_once` | `exclusive` | `targeted`

**提交触发（Browser 行为）：**

| kind | 何时发 `interaction.submit` |
|---|---|
| `button` | 点击 |
| `select` / `radio` | 选中一项 |
| `checkbox` | 每次 toggle |
| `checkbox_group` | 用户点 `submit_label` |
| `text_input` | 单行：Enter 或点 `submit_label`；多行（`multiline=true`）：仅点 `submit_label` |

typing 中间态 **不** 发 interaction；只有上述触发才进入 §9.6 流程。

### 3.9 Bot Markdown 渲染

`format=markdown` 与 `format=unsafe-markdown` 的 Bot 消息由 Browser 使用 **markdown-it + DOMPurify** 渲染（`Message.text` 为 Markdown 源码；净化后 `v-html` 输出）。

#### 3.9.1 `format` 写入与校验

| `format` | 谁可以写入 | Gateway / 服务端校验 |
|---|---|---|
| `plain` | 任意 Bot；用户消息固定为此值 | 无额外限制 |
| `markdown` | 任意已安装 Bot（`send_message` / `start_stream`） | `message.format` 须为 `plain` \| `markdown` \| `unsafe-markdown`；非法值 → `422 BOT_EFFECT_INVALID` |
| `unsafe-markdown` | 仅 **official bot** 与 **platform bot 服务端直写** | **BotConnection** 在 `delivery_result` 校验：连接时缓存 `bot_apps.visibility=official`；非 official bot 在 effect 中使用 `unsafe-markdown` → `delivery_ack{failed, BOT_EFFECT_INVALID, message: "unsafe-markdown format is only allowed for official bots"}`，**不**转发 ChatChannel |

- **official bot**：BotRegistry `bot_apps.visibility = "official"` 的 bot。
- **platform bot**：§9.2 `bot_id = 00000000-0000-7000-8000-000000000600`；`/help` / `/permission` 响应由 ChatChannel **直接** `INSERT messages(..., format='unsafe-markdown')`，不经 Bot Gateway。
- **第三方 Bot**：**只能**使用 `plain` 或 `markdown`；**不得**请求 `unsafe-markdown`。
- **持久化**：`messages.format` 原样存储；Browser 投影 **不**推断、**不**升级 format（读行即得）。

`send_message` / `start_stream` 的 `message.format` 允许值：`plain` | `markdown` | `unsafe-markdown`（subject to §3.9.1 身份限制）。`update_message` **不**改 `format`（仅 text / components）。

#### 3.9.2 渲染适用范围与 streaming

- 仅 `sender.kind=bot` 且 `format ∈ {markdown, unsafe-markdown}`，且消息内容可见（`status` 为 `normal` / `edited` / `failed` 等可展示正文的状态）。
- `stream_state=streaming`：按 **纯文本** 追加（不解析 Markdown）；`stream_state ∈ {final, abandoned}` 且 format 为 markdown 类时 **一次性**完整渲染。

#### 3.9.3 共用 Markdown 语法（两种 format 相同）

| 语法 | 渲染 |
|---|---|
| `**粗体**` / `*斜体*` | 粗体 / 斜体 |
| `` `行内代码` `` / ` ```代码块``` ` | 行内 code / pre |
| `#` … `######` 标题 | h1–h6 |
| `-` / `*` / `1.` 列表 | ul / ol |
| `[文字](url)` | 链接（§3.9.5） |
| `![alt](url)` | 图片（§3.9.6） |
| inline HTML | 经 DOMPurify；允许标签见 §3.9.4 / §3.9.7 |

#### 3.9.4 `format=markdown` 限制（默认；第三方 Bot 必须使用此档或 `plain`）

**链接（§3.9.5 表内 `format=markdown` 行）**

**inline HTML 允许标签（strict 白名单）：**

`p`, `br`, `strong`, `b`, `em`, `i`, `code`, `pre`, `span`, `div`, `ul`, `ol`, `li`, `h1`, `h2`, `h3`, `h4`, `h5`, `h6`, `blockquote`, `a`, `img`, `hr`, `button`（仅 Browser 将 `/command:*` 虚拟链接渲染为 chip 时生成；Bot raw HTML 中的 `button` 亦保留）

**允许属性（strict）：** `href`, `src`, `alt`, `title`, `class`, `target`, `rel`, `referrerpolicy`, `loading`, `type`, `data-command-name`

**不在白名单内的标签**（含 `table`, `details`, `iframe`, `script` 等）**剔除**。

#### 3.9.5 `format=unsafe-markdown` 限制（仅 official / platform）

在 `format=markdown` 基础上 **仅**放宽：

1. **站外链接可点击**（见链接表）。
2. **更宽的 inline HTML 白名单（relaxed）**（§3.9.7）。

其余规则（危险协议、图片、事件属性、streaming）与 `format=markdown` **相同**。

#### 3.9.6 链接规则

| URL 类型 | `format=markdown` | `format=unsafe-markdown` |
|---|---|---|
| 站内（`*.kuma.homes` 或相对路径 `/...`），`http:`/`https:` | 可点击 `<a>`；`target="_blank"` + `rel="noopener noreferrer"` | 同左 |
| 站外 `http:`/`https:` | **不可点击** `<span>`（无 `href`）；`title` 保留 URL 便于复制 | 可点击 `<a>`；`target="_blank"` + `rel="noopener noreferrer"` |
| 虚拟链接 `/command:<name>` | 渲染为 chip `<button>`；点击打开命令帮助（§3.9.8） | 同左 |
| `javascript:` / `data:` / `vbscript:` / `//` 协议相对 URL | **阻断**（两种 format） | **阻断** |

#### 3.9.7 HTML 安全（DOMPurify）

**两种 format 均禁止（永远剔除）：**

`script`, `style`, `iframe`, `object`, `embed`, `form`, `input`, `textarea`, `select`, `option`, `link`, `meta`, `base`, `template`, `slot`

**事件与动态属性：** `onclick`, `onerror`, `onload` 等 **on\*** 属性由 DOMPurify 默认剔除（两种 format）。

**`format=markdown`：** 仅 §3.9.4 strict 标签/属性白名单。

**`format=unsafe-markdown` relaxed 允许标签：**

`h1`–`h6`, `br`, `b`, `i`, `strong`, `em`, `a`, `pre`, `code`, `img`, `tt`, `div`, `ins`, `del`, `sup`, `sub`, `p`, `picture`, `ol`, `ul`, `table`, `thead`, `tbody`, `tfoot`, `blockquote`, `dl`, `dt`, `dd`, `kbd`, `q`, `samp`, `var`, `hr`, `ruby`, `rt`, `rp`, `li`, `tr`, `td`, `th`, `s`, `strike`, `summary`, `details`, `caption`, `figure`, `figcaption`, `abbr`, `bdo`, `cite`, `dfn`, `mark`, `small`, `source`, `span`, `time`, `wbr`, `button`

**relaxed 允许属性：** strict 属性集，另加 `abbr`, `align`, `axis`, `border`, `char`, `charoff`, `charset`, `checked`, `cite`, `clear`, `cols`, `colspan`, `compact`, `coords`, `datetime`, `dir`, `disabled`, `enctype`, `for`, `frame`, `headers`, `height`, `hreflang`, `hspace`, `id`, `ismap`, `itemprop`, `itemscope`, `itemtype`, `label`, `lang`, `longdesc`, `maxlength`, `media`, `method`, `multiple`, `name`, `nohref`, `noshade`, `nowrap`, `open`, `progress`, `prompt`, `readonly`, `rev`, `role`, `rows`, `rowspan`, `rules`, `scope`, `selected`, `shape`, `size`, `span`, `srcset`, `start`, `summary`, `tabindex`, `usemap`, `valign`, `value`, `width`（及 §3.9.4 strict 所列属性）

Bot **应以 Markdown 为主**；HTML 为补充，不应依赖被剔除的标签。

#### 3.9.8 图片规则（两种 format 相同）

- `http:`/`https:` 的 `src` **允许**（含站外 CDN）；渲染 `<img>`。
- 所有图片：`referrerpolicy="no-referrer"` + `loading="lazy"`。
- `javascript:` / `data:` 等危险 `src` **阻断**，降级为纯文本。

#### 3.9.9 Slash command chip 虚拟链接

Platform `/help`、`/permission` 等引用 slash 命令时使用虚拟 href：

```markdown
[`/help`](/command:help) — 查看可用命令
```

- 语法：`` [`显示文字`](/command:<canonical_name>) ``（`<canonical_name>` 不含前导 `/`）。
- Browser 将 `/command:*` 渲染为 **chip**；点击打开命令帮助（manifest lookup），**不**离开页面。
- 任意 Bot 的 markdown / unsafe-markdown 均可使用；Browser 同等处理。

### 3.10 Channel Pin

Channel Pin 是服务端维护、固定在聊天区顶部的 UI 投影；**不进** `messages` 表 / `GET .../messages` 分页；交互 locator 为 **`pin_id` + `component_id`**（§9.6.3）。

#### 3.10.1 `PinMessageProjection`

Pin 内嵌投影为 **独立类型**，不复用 timeline `WireChatMessage`：

```ts
interface PinMessageProjection {
  projection_id: string;          // 内部投影 id；非 timeline message_id
  channel_id: string;
  sender: MessageSender;          // bot | user（platform pin 用 platform bot）
  type: "text";                   // 固定 text
  format: "plain" | "markdown" | "unsafe-markdown";
  text: string | null;
  components: MessageComponent[];
  created_at: string;
  updated_at: string;
}
```

**不包含**：`command_id`、`reply_to`、`reply_snapshot`、`attachments`、`sticker`、`stream_state`、`edited_at` / `deleted_at` / `recalled_at`。组件校验与 timeline 相同（§3.8）。

#### 3.10.2 `PinMessageDraft` / `PinMessagePatch`

Bot effects 与平台内部 set **不得**提交完整 `PinMessageProjection`。服务端生成 `projection_id`、`channel_id`、`sender`、`created_at`、`updated_at`。

```ts
/** set_channel_pin */
interface PinMessageDraft {
  format: "plain" | "markdown" | "unsafe-markdown";
  text: string | null;
  components: MessageComponent[];
}

/** update_channel_pin */
interface PinMessagePatch {
  format?: "plain" | "markdown" | "unsafe-markdown";
  text?: string | null;
  components?: MessageComponent[];
}
```

#### 3.10.3 `ChannelPin`

```json
{
  "pin_id": "00000000-0000-7000-8000-00000000a01",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "pin_kind": "session_control",
  "pin_owner_kind": "platform",
  "pin_owner_id": "00000000-0000-7000-8000-000000000600",
  "priority": 0,
  "session_id": "00000000-0000-7000-8000-000000000901",
  "source_message_id": null,
  "pinned_by": null,
  "pinned_at": null,
  "expires_at": null,
  "last_pin_event_id": "01J000000000000000000000001",
  "message": { /* PinMessageProjection */ }
}
```

| 字段 | 说明 |
|------|------|
| `pin_kind` | `session_control` \| `bot_control` \| `announcement` \| `pinned_message` |
| `pin_owner_kind` | `platform` \| `bot` \| `user`（`pinned_message` 为 `user`） |
| `pin_owner_id` | `bot_id` / `user_id` / platform bot id |
| `session_id` | `session_control` 必填 |
| `source_message_id` | `pinned_message` 必填 |
| `pinned_by` | `pinned_message`：UserSummary |
| `pinned_at` | `pinned_message`：ISO 时间 |
| `expires_at` | 可选；Browser **仅展示**，不得本地删除 pin |
| `last_pin_event_id` | 最近一次 `channel.pin.set` 或 `channel.pin.updated` 的 `event_id`；用于 no-op ack（§6.7） |

**多槽与 replace**：`channel_pins: ChannelPin[]`，0..N（建议上限 **8**）。`session_control` 每频道至多 1 条，按 `pin_kind` replace。`pinned_message` 每 `source_message_id` 至多 1 条。`bot_control` / `announcement`：`set_channel_pin` 按 `(bot_id, pin_kind)` replace；`update_channel_pin` 按 `pin_id`。`priority` 升序渲染。Session 结束 clear 仅当 pin 的 `session_id` **匹配**结束 session。

## 4. 首屏

### 4.1 Bootstrap

```http
GET /api/chat/bootstrap?channel_id=00000000-0000-7000-8000-000000000201
```

`channel_id` 可选。未传时后端选择**当前用户已加入频道列表**中最近活跃的一个；若用户尚未加入任何频道则 `active_channel=null`。

响应：

```json
{
  "me": {
    "user_id": "00000000-0000-7000-8000-000000000101",
    "display_name": "alice",
    "avatar_url": "https://example.com/avatar.png"
  },
  "channels": [
    {
      "channel_id": "00000000-0000-7000-8000-000000000201",
      "kind": "channel",
      "visibility": "private",
      "title": "克利夫兰先导报",
      "avatar_url": "https://example.com/channel.png",
      "member_count": 11,
      "role": "member",
      "status": "active",
      "unread_count": 3,
      "last_read_event_id": "01J...",
      "last_message_preview": "Zemo: 我也不行",
      "last_message_at": "2026-06-21T05:24:00Z",
      "last_event_id": "01J..."
    }
  ],
  "active_channel": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "kind": "channel",
    "visibility": "private",
    "title": "克利夫兰先导报",
    "topic": "频道说明",
    "avatar_url": "https://example.com/channel.png",
    "member_count": 11,
    "role": "member",
    "status": "active",
    "created_at": "2026-06-20T12:00:00Z",
    "updated_at": "2026-06-21T05:00:00Z"
  },
  "messages": {
    "items": [],
    "next_cursor": null
  },
  "channel_pins": [],
  "event_state": {
    "per_channel": {
      "00000000-0000-7000-8000-000000000201": "01J..."
    }
  }
}
```

`channel_pins`：当前频道 active pin 快照（§3.10）。**Normative 不变量**：对任意 `channel_id`，`channel_pins` **必须**等价于将所有 `event_id <= event_state.per_channel[channel_id]` 的 `channel.pin.*` 事件 fold 后得到的当前 pin 集合；`channel_pins` 与 `event_state.per_channel[channel_id]` **必须**来自同一读取快照，禁止跨异步读拼装。群聊成员可见；**DM 恒 `[]`**。

`event_state.per_channel` 是 per-channel cursor map：`{ channel_id: last_event_id }`。每个 channel_summary 项也带自身 `last_event_id`，二者一致。HTTP 恢复（§10.3）用此 map 作 `cursors` 参数。

空频道列表：

```json
{
  "me": {
    "user_id": "00000000-0000-7000-8000-000000000101",
    "display_name": "user-00000000",
    "avatar_url": null
  },
  "channels": [],
  "active_channel": null,
  "messages": {
    "items": [],
    "next_cursor": null
  },
  "channel_pins": [],
  "event_state": { "per_channel": {} }
}
```

## 5. 频道

### 5.1 获取频道列表

```http
GET /api/chat/channels
```

响应：

```json
{
  "items": [],
  "next_cursor": null
}
```

### 5.2 获取频道详情

```http
GET /api/chat/channels/{channel_id}
```

响应：

```json
{
  "channel": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "kind": "channel",
    "visibility": "private",
    "title": "克利夫兰先导报",
    "topic": "频道说明",
    "avatar_url": null,
    "member_count": 11,
    "role": "member",
    "status": "active",
    "created_at": "2026-06-20T12:00:00Z",
    "updated_at": "2026-06-21T05:00:00Z"
  },
  "channel_pins": []
}
```

`channel_pins`：与 §4.1 相同不变量；DM 恒 `[]`。

### 5.2b 创建频道

```http
POST /api/chat/channels
Idempotency-Key: client-key-channel-create
```

请求：

```json
{
  "title": "新频道",
  "topic": null,
  "avatar_attachment_id": null,
  "visibility": "private",
  "initial_members": [
    {
      "user_id": "00000000-0000-7000-8000-000000000102",
      "role": "member"
    }
  ]
}
```

字段：

- `title`：必填，非空。
- `topic`、`avatar_attachment_id`：可选，默认 `null`。`avatar_attachment_id` 当前仅接受 `null`（非空值返回 `422 INVALID_MESSAGE`）。
- `visibility`：`private` | `public_unlisted` | `public_listed`，默认 `private`。`public_listed` 的频道进入公开目录（§5.6）。
- `initial_members`：可选，创建时一并加入的成员（不含创建者）。每项 `{ user_id, role }`，`role` ∈ `member` | `admin`（不允许 `owner`，owner 固定为创建者）。

响应：

```json
{
  "channel": {},
  "membership": {
    "role": "owner",
    "joined_at": "2026-06-24T03:00:00Z"
  }
}
```

事件（同事务追加，经 fanout 广播给在线成员）：

- `channel.created`（actor=创建者，payload 含 channel_id/kind/visibility/title）
- `member.joined`（创建者，actor=system）
- 对每个 `initial_members`：`member.joined`（actor=system）
- `system.notice`（notice_kind=`channel.created`，actor=创建者）

权限：

- **创建者自动成为 `owner`**，并写入 `members` + UserDirectory.my_channels projection（同事务 outbox）。
- `POST /api/chat/channels` 只创建 `kind="channel"`，请求不接受 `kind` 字段。任意已认证 Browser 用户可创建 `kind="channel"` 频道。DM 不通过本端点创建；DM 见 **§5.2c** `POST /api/chat/dms`。
- endpoint 必须存在——后续 admin UI / 初始化工具 / 测试 fixture 都经此正式入口，不靠 `/internal/*` 旁路。

路由与幂等：创建频道的幂等由 `UserDirectory(creator_user_id)` 协调，不由 Worker 现场 mint 的 `ChatChannel` DO 承担。Worker 路由到 `UserDirectory(user_id)`，后者在其 `idempotency_keys` 事务内 mint `channel_id`（UUIDv7，即 `ChatChannel` DO name），状态机 `creating`→`completed`，持久化 `channel_id`，再调用 `ChatChannel(channel_id).createChannel`（单事务原子写入，`channel_meta` 存在性即幂等 guard）。同一 `(user, operation=channel.create, key)` + 相同 `request_hash` 重试命中同一 `UserDirectory` DO → 同一 `channel_id` → 同一 `ChatChannel` DO → 缓存结果；不同 `request_hash` 返回 `409 IDEMPOTENCY_CONFLICT`。崩溃窗口：`status=creating` 时 retry 重新调用同一 `ChatChannel(channel_id).createChannel`（幂等返回已提交行）后标 `completed`，不重复建群。跨 DO 仍为 best-effort（无 2PC）。

### 5.2c 打开或获取 DM

get-or-create 当前用户与目标用户之间的一对一 DM。不是普通频道创建。

```http
POST /api/chat/dms
Authorization: Bearer <toolbear_browser_jwt>
Idempotency-Key: client-key-dm-open
Content-Type: application/json
```

请求：

```json
{
  "recipient_user_id": "00000000-0000-7000-8000-000000000102"
}
```

规则：

- `recipient_user_id` 必填；须存在于 ToolBear users 数据源；不得等于 `current_user_id`。
- 不要求共同频道、隐私开关或黑名单检查。
- Pair 唯一性由 `DMDirectory(pair_key)` 协调；A↔B 恒为同一 `channel_id`。
- 幂等由 `UserDirectory(current_user_id)` 协调：同 `Idempotency-Key` + 异 `recipient_user_id` → `409 IDEMPOTENCY_CONFLICT`。
- 响应必须返回完整 `ChannelSummary`（含 `unread_count` / `last_message_*` / `dm_peer` UserSummary）。
- DM 频道：`kind="dm"`；`ChannelSummary.dm_peer` 为对端 UserSummary。
- DM 上频道管理/Bot 路径返回 `409 UNSUPPORTED_CHANNEL_KIND`；`GET .../commands` 返回空 manifest `{version:0,items:[]}` 例外。

错误码：`INVALID_DM_TARGET`、`DM_TARGET_NOT_FOUND`、`UNSUPPORTED_CHANNEL_KIND`、`IDEMPOTENCY_CONFLICT`。

### 5.3 更新频道

```http
PATCH /api/chat/channels/{channel_id}
Idempotency-Key: client-key-channel-update
```

请求：

```json
{
  "title": "新标题",
  "topic": "新说明",
  "avatar_attachment_id": "00000000-0000-7000-8000-000000000501",
  "visibility": "private"
}
```

字段均可选；未传字段不变。

响应：

```json
{
  "channel": {}
}
```

### 5.4 解散群聊

```http
POST /api/chat/channels/{channel_id}/dissolve
Idempotency-Key: client-key-channel-dissolve
```

仅 `kind="channel"` 的 owner 可调用。事务提交后频道 `status` 固定为 `dissolved`，服务端生成 `channel.dissolved` 和 `system.notice` 事件。已解散频道仍可通过频道列表/详情向当前成员返回 `status="dissolved"` 作为 tombstone；所有后续写入类操作和 WebSocket command 返回 `409 CHANNEL_DISSOLVED`，同一 Idempotency-Key 的重复 dissolve 返回同一结果。

响应：

```json
{
  "channel": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "status": "dissolved",
    "updated_at": "2026-06-21T05:30:00Z"
  }
}
```

### 5.5 标记已读

WebSocket command frame：

```json
{
  "frame_type": "command",
  "command": "channel.mark_read",
  "command_id": "00000000-0000-7000-8000-000000000511",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "last_read_event_id": "01J..."
  }
}
```

`last_read_event_id` 是 per-channel 单调 UUIDv7，只允许单调前进（新值 > 旧值才接受）。要求当前用户在该频道是 active 成员。

Committed ack（ack 携带 read-state payload，不是 message 投影，不含 `event_id`）：

```json
{
  "frame_type": "command_ack",
  "command": "channel.mark_read",
  "command_id": "00000000-0000-7000-8000-000000000511",
  "status": "committed",
  "payload": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "last_read_event_id": "01J...",
    "unread_count": 0
  }
}
```

`payload` 只含 `{ channel_id, last_read_event_id, unread_count }`，无 `event_id`、无 message 投影、无 channel timeline event 追加；read-state 留在 user-local UserDirectory。

Semantics: handled by UserConnection; state written to UserDirectory; requires active `my_channels` row; monotonic (older cursor → return stored); **read-state does not create channel timeline event**; `command_id` echoed; durable idempotency via monotonic cursor。

**Read-state is not live delivery state:** `last_read_event_id` 表示当前用户已将频道标为已读至该 event。它**不是** WebSocket delivery cursor，**不用于** WS replay、重连恢复、fanout lease 刷新或 gap repair。HTTP bootstrap/history/events API 负责恢复。服务端必须保持 `(user_id, channel_id)` 上 `last_read_event_id` 单调前进，并向该用户所有 live session 广播 `read_state_updated`（§5.5 multi-session note）。

Multi-session note: if the same user has multiple active WS sessions, UserConnection may broadcast a non-timeline `read_state_updated` frame to the user's other sessions：

```json
{
  "frame_type": "read_state_updated",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "last_read_event_id": "01J...",
  "unread_count": 0
}
```

This frame is user-local state, not a channel event, and must not be written to `ChatChannel.events`。

### 5.6 公开频道目录

```http
GET /api/chat/channels/directory?q=game&limit=50&cursor=opaque-cursor
```

只返回 `visibility=public_listed` 且 `status=active` 的频道。

> **实现注：** 当前实现 `last_message_preview=null`（preview 文本未纳入 read model，避免 stale/profanity 问题，留待 future plan 回填）与 `unread_count=0`（discover 列表不计算真实未读，左侧 rail 已为已加入频道显示未读）。`kind`/`visibility` 为目录行的常量（`channel`/`public_listed`）。排序 = `COALESCE(last_message_at, updated_at) DESC, channel_id DESC`，cursor 为该 tuple 的 base64url keyset。`role` 由 `ChatChannel(channel_id)/internal/summary.my_role`（字段名 `my_role`）解析，仅对调用者已 active-member 的行非 null；`last_read_event_id` 来自 `UserDirectory/my-channels` 投影。

响应：

```json
{
  "items": [
    {
      "channel_id": "00000000-0000-7000-8000-000000000201",
      "kind": "channel",
      "visibility": "public_listed",
      "title": "公开频道",
      "avatar_url": null,
      "member_count": 42,
      "role": null,
      "status": "active",
      "unread_count": 0,
      "last_read_event_id": null,
      "last_message_preview": null,
      "last_message_at": "2026-06-21T05:24:00Z"
    }
  ],
  "next_cursor": null
}
```

### 5.7 加入公开频道

```http
POST /api/chat/channels/{channel_id}/join
Idempotency-Key: client-key-channel-join
```

响应：

```json
{
  "channel": {},
  "membership": {
    "role": "member",
    "joined_at": "2026-06-21T05:30:00Z"
  }
}
```

### 5.8 创建邀请

```http
POST /api/chat/channels/{channel_id}/invites
Idempotency-Key: client-key-invite-create
```

请求：

```json
{
  "expires_in_seconds": 604800,
  "max_uses": null
}
```

响应：

```json
{
  "invite_code": "invite-code-abc123",
  "invite_url": "https://lilium.kuma.homes/chat/invites/invite-code-abc123",
  "expires_at": "2026-06-28T05:30:00Z",
  "max_uses": null
}
```

`invite_url` 是 Browser 可打开的 SPA 邀请页 URL，由 Worker 配置 `API_BASE_URL`（ToolBear 前端 origin，如 `https://lilium.kuma.homes`）与 `/chat/invites/{invite_code}` 拼接而成；**不是** Worker API host（`chat.kuma.homes`）。

邀请码原文只返回一次。邀请码明文存储在服务端（可重复使用），按 principal 不命名空间化（邀请码是频道级凭据）。

### 5.9 接受邀请

```http
POST /api/chat/invites/{invite_code}/accept
Idempotency-Key: client-key-invite-accept
```

该 endpoint 的 URL 不含 `channel_id`，服务端内部按 `invite_code` 定位频道。索引 lag 窗口内返回 `409 ROUTE_INDEX_PENDING`。邀请码不存在、不可见、已撤销或已过期返回 `404 INVITE_NOT_FOUND`。

响应：

```json
{
  "channel": {},
  "membership": {
    "role": "member",
    "joined_at": "2026-06-21T05:30:00Z"
  }
}
```

### 5.10 邀请预览

加入前预览邀请：展示群名、头像、邀请人、成员数等。**read-only，不产生任何 join 副作用**。预览与接受（§5.9）必须保持分离。

```http
GET /api/chat/invites/{invite_code}
```

响应（当前用户未加入）：

```json
{
  "invite": {
    "invite_code": "invite-code-abc123",
    "expires_at": "2026-06-28T05:30:00Z",
    "max_uses": null
  },
  "channel": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "kind": "channel",
    "visibility": "private",
    "title": "只想听你说",
    "avatar_url": null,
    "member_count": 1060,
    "status": "active"
  },
  "inviter": {
    "user_id": "00000000-0000-7000-8000-000000000101",
    "display_name": "kuma",
    "avatar_url": null
  },
  "sample_members": [
    {
      "user_id": "00000000-0000-7000-8000-000000000102",
      "display_name": "alice",
      "avatar_url": null
    }
  ],
  "my_membership": {
    "status": "not_joined",
    "channel_id": null
  }
}
```

`my_membership.status` 取值：

- `not_joined`
- `active`
- `left`
- `removed`（v2.31 delta：保留值，正常写路径不可达，见 §7.1b）

当前用户已是 active 成员时：

```json
{
  "my_membership": {
    "status": "active",
    "channel_id": "00000000-0000-7000-8000-000000000201"
  }
}
```

语义：

- Read-only。
- 不增加邀请使用计数。
- 不创建 member row。
- 不写 channel event。
- 不暴露频道私有历史。
- `sample_members` 只返回 UserSummary 风格的展示数据；服务端应限制数量，建议上限 3。
- 邀请不存在 / 已过期 / 已撤销 / 不可见：`404 INVITE_NOT_FOUND`。
- invite-code 路由索引 lag：`409 ROUTE_INDEX_PENDING`（与 §5.9 接受邀请同一路由约束）。
- 频道已解散：`409 CHANNEL_DISSOLVED` 或 `channel.status="dissolved"`，实现需保持一致。

### 5.11 启动 live fanout：`session.live_start`

WebSocket `open` 后，Browser socket manager **必须自动**发送本 command。这不是用户可见的 per-channel 订阅操作；它为当前用户全部 **active** 成员频道启动 live fanout。

```json
{
  "frame_type": "command",
  "command": "session.live_start",
  "command_id": "00000000-0000-7000-8000-000000000001",
  "payload": {}
}
```

Committed ack：

```json
{
  "frame_type": "command_ack",
  "command": "session.live_start",
  "command_id": "00000000-0000-7000-8000-000000000001",
  "status": "committed",
  "payload": {
    "session_id": "00000000-0000-7000-8000-000000000101",
    "subscribed_channel_count": 12,
    "lease_expires_at": "2026-06-27T13:10:00Z"
  }
}
```

语义：

- 为当前用户全部 active 成员频道注册 `ChannelFanout` fanout lease（经 `UserConnection` 本地 `live_channel_leases`）。
- 对当前 WebSocket session **幂等**；同一 `command_id` 重试返回等价 ack。
- 已 live 的 session 用不同 `command_id` 重发 **不得**为同一 `(session_id, channel_id)` 创建重复 lease。
- **不得** replay 历史 channel events。
- **不得**接受或处理 per-channel cursor。
- **不得**发送历史 `message.created` / `message.updated` / `message.deleted` 等 event。
- 部分频道 lease 瞬态失败 → `503 CHAT_WORKER_UNAVAILABLE`（除非实现可证明确定性 partial retry 路径）。
- Connect 握手期间 **不得**执行本逻辑；仅在客户端显式 command 时执行。
- 任一 active lease 到期时，`UserConnection` **主动关闭该 session 的 WebSocket**（close reason: `lease_expired`）；客户端应重连并走 HTTP 恢复。

**non-goal：** 不暴露 `channel.subscribe` / `channel.unsubscribe`。连接并在 `session.live_start` committed 后，live WS 接收全部 active 成员频道的新事件。客户端按 `event.channel_id` 更新 sidebar/unread 或 active timeline；所有 event 按 `(channel_id, event_id)` dedupe。

### 5.12 Session heartbeat：`session.heartbeat`

Socket 打开期间低频发送，仅刷新 lease TTL。

```json
{
  "frame_type": "command",
  "command": "session.heartbeat",
  "command_id": "00000000-0000-7000-8000-000000000002",
  "payload": {}
}
```

Committed ack：

```json
{
  "frame_type": "command_ack",
  "command": "session.heartbeat",
  "command_id": "00000000-0000-7000-8000-000000000002",
  "status": "committed",
  "payload": {
    "session_id": "00000000-0000-7000-8000-000000000101",
    "lease_expires_at": "2026-06-27T13:14:00Z"
  }
}
```

语义：

- 刷新 `UserConnection.live_sessions.last_seen_at`。
- **必须**从 `UserDirectory /my-channels` 重载当前 active memberships，再处理本地 lease（**不得** blind refresh 全部 `status='active'` 行）。
- 对仍 active 的频道：延长 `expires_at`；若 `membership_version` 升高则写回 `live_channel_leases` 并 upsert `ChannelFanout`。
- 对不再 active 的频道：将本地 `live_channel_leases.status` 标为 `closed`，best-effort `/lease-revoke`，**不得** upsert 到 `ChannelFanout`。
- 本地 `status='closed'` 或因 `/deliver` 返回 `membership_not_active` / `membership_stale` 而被 fanout 删除的 lease，**不得**被 heartbeat 复活。
- **不得** replay events；**不得** gap repair；**不得**携带 cursor。
- Session 尚未 `session.live_start` → `409 SESSION_NOT_LIVE` 或 `422 INVALID_COMMAND`（实现择一，全仓库一致）。
- 推荐 lease TTL：10 分钟；推荐 heartbeat 间隔：4 分钟（active tab）。
- 若在 TTL 内未心跳导致 lease 到期，server 会主动 close 当前 WS session（`lease_expired`）；此期间漏掉的事件仍按 best-effort 语义处理（见 §10.6 / §12）。

## 6. 消息

### 6.1 拉取历史消息

```http
GET /api/chat/channels/{channel_id}/messages?before=00000000-0000-7000-8000-000000000301&limit=50
```

`before` 可选。未传时返回最新消息页。

响应：

```json
{
  "items": [],
  "next_cursor": "opaque-cursor"
}
```

响应只包含当前用户可见的非 deleted / non recalled 消息。已删除或撤回的消息不出现在历史分页中。

### 6.1b 频道事件 gap 恢复

HTTP 是 Browser 权威状态恢复的 source of truth。重连、tab resume、active channel 进入、`session.live_start` ack 后若需补齐 timeline，使用本端点（或 §6.1 messages，若足以恢复全部 Browser-visible message 状态）。

```http
GET /api/chat/channels/{channel_id}/events?after_event_id=00000000-0000-7000-8000-000000000301&limit=100
```

响应：

```json
{
  "events": [],
  "latest_event_id": "00000000-0000-7000-8000-000000000301",
  "next_cursor": null
}
```

`events[]` 每项为 Browser-visible event 投影（与 §10.4 EventEnvelope 同形，含 replay 过滤规则 §10.3）。`after_event_id` 为空时从频道最早可见 event 起（或实现定义的 floor）。多频道恢复可用全局 `GET /api/chat/events?cursors=...`（§10.3）；单频道 active timeline 同步优先本端点。

**Recovery triggers（normative）：** initial app load；WebSocket reconnect；`session.live_start` committed；active channel route enter；tab 从 hidden/suspended resume；疑似本地 event gap；local cache reset；timeline 分页；**Channel Pin 状态恢复**（§10.6）。

### 6.2 发送消息

WebSocket command frame（`command_id` 既是 ack 关联又是 durable 幂等键）：

```json
{
  "frame_type": "command",
  "command": "message.send",
  "command_id": "00000000-0000-7000-8000-000000000411",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "type": "text",
    "text": "hello @alice",
    "reply_to_message_id": null,
    "attachment_ids": [],
    "mentions": [
      {
        "user_id": "00000000-0000-7000-8000-000000000101",
        "start": 6,
        "end": 12
      }
    ]
  }
}
```

图片消息 command：

```json
{
  "frame_type": "command",
  "command": "message.send",
  "command_id": "00000000-0000-7000-8000-000000000412",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "type": "image",
    "text": "",
    "reply_to_message_id": null,
    "attachment_ids": ["00000000-0000-7000-8000-000000000501"],
    "mentions": []
  }
}
```

Sticker 消息 command：`type:"sticker"` + `sticker_id`（发送方个人表情库 item id）。服务端把 `sticker_id` resolve 为 canonical `attachment_id`，消息投影同时返回 `sticker_id` 与 `attachment_id`（见 §3.4 sticker 投影）。

```json
{
  "frame_type": "command",
  "command": "message.send",
  "command_id": "00000000-0000-7000-8000-000000000411",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "type": "sticker",
    "text": "",
    "reply_to_message_id": null,
    "attachment_ids": [],
    "sticker_id": "00000000-0000-7000-8000-000000000901",
    "mentions": []
  }
}
```

Sticker send 规则：

- `sticker_id` 必须属于当前用户（发送方个人表情库 item）。
- 服务端 resolve `sticker_id` 为 canonical `attachment_id`；消息投影同时返回 sender-side `sticker_id` 与 canonical `attachment_id`。
- 接收方把该 sticker 存入自己表情库时用 `channel_id + attachment_id`（不用 `sticker_id`，不用 `message_id`）。
- 同一 `command_id` + 同一 payload 重发 → 返回同一 committed ack payload（幂等）。
- 同一 sticker + 新 `command_id` → 创建新消息。
- 发送前该 sticker 已从发送方表情库移除 → `STICKER_NOT_FOUND`。
- 发送后该 sticker 从发送方表情库移除，不影响已存在的 sticker 消息。

Worker 接受 command 并在事务提交后返回 committed_ack（ack 携带 canonical mutation payload，`payload.message` 为完整 Browser 投影，与历史分页 / event frame 同一 `projectMessageForBrowser` builder 产物）：

```json
{
  "frame_type": "command_ack",
  "command": "message.send",
  "command_id": "00000000-0000-7000-8000-000000000411",
  "status": "committed",
  "payload": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "event_id": "01J...",
    "message": {
      "message_id": "00000000-0000-7000-8000-000000000301",
      "command_id": "00000000-0000-7000-8000-000000000411",
      "channel_id": "00000000-0000-7000-8000-000000000201",
      "sender": {
        "kind": "user",
        "user": {
          "user_id": "00000000-0000-7000-8000-000000000101",
          "display_name": "Zemo",
          "avatar_url": null
        }
      },
      "type": "text",
      "format": "plain",
      "status": "normal",
      "stream_state": "none",
      "text": "hello @alice",
      "reply_to": null,
      "reply_snapshot": null,
      "attachments": [],
      "components": [],
      "mentions": [
        {
          "user_id": "00000000-0000-7000-8000-000000000101",
          "start": 6,
          "end": 12
        }
      ],
      "created_at": "2026-06-21T05:30:00Z",
      "updated_at": "2026-06-21T05:30:00Z",
      "edited_at": null,
      "deleted_at": null,
      "recalled_at": null
    }
  }
}
```

`payload.message.command_id` == 该 `message.send` 的 command_id（发送方 optimistic UI 关联）。`payload.message` 是 mutation 后的 Browser-visible Message 投影，与 §3.4 Message model、§6.1 历史分页、§10.4 event frame 同形。

前端收到 committed_ack 后即可把本地 pending 绑定到 server `message_id`，即使 event frame 延迟也能正确渲染占位。event frame 仍是最终 timeline 状态来源。

幂等行为（幂等缓存存**完整 committed ack payload**）：

- 客户端用同一 `command_id` 重发 `message.send`（重试、丢包重传）且请求体一致 → 服务端命中 `idempotency_keys` 缓存（`operation_id` = `command_id`），返回与首次**完全相同的 committed ack payload**（完整 `payload.message` 投影），不创建新消息、不广播新 event。
- 客户端用同一 `command_id` 但改了 `text`/`reply_to`/`mentions` 等字段 → `command_error`，`code=IDEMPOTENCY_CONFLICT`，`retryable=false`。前端应视为编程错误（复用 key 改 body），不应自动重试。
- 客户端发新消息即使文本相同也必须用新的 `command_id`；同文本 + 新 `command_id` → 创建新消息。
- 重复重试返回的 ack payload 是首次提交时的快照；若事后 profile display_name/avatar_url 变更，幂等重放仍可能返回旧的 display 数据（idempotency replay 优先稳定提交结果；正常 history/event replay 按既有策略实时 resolve 新 profile）。可接受。
- `message.created` event payload 的 `sender` 是 Browser projection（实时 `resolveUserSummaries`），不持久化 UserSummary；详见 §10.3 与 §10.4。ack 与 event 共用同一 `projectMessageForBrowser` builder。

随后广播：

```json
{
  "frame_type": "event",
  "api_version": "lilium.chat.v1",
  "event_id": "01J...",
  "type": "message.created",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "occurred_at": "2026-06-21T05:30:00Z",
  "payload": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "event_id": "01J...",
    "message": {
      "message_id": "00000000-0000-7000-8000-000000000301",
      "command_id": "00000000-0000-7000-8000-000000000411",
      "channel_id": "00000000-0000-7000-8000-000000000201",
      "sender": {
        "kind": "user",
        "user": {
          "user_id": "00000000-0000-7000-8000-000000000101",
          "display_name": "Zemo",
          "avatar_url": null
        }
      },
      "type": "text",
      "format": "plain",
      "status": "normal",
      "stream_state": "none",
      "text": "hello @alice",
      "reply_to": null,
      "reply_snapshot": null,
      "attachments": [],
      "components": [],
      "mentions": [
        {
          "user_id": "00000000-0000-7000-8000-000000000101",
          "start": 6,
          "end": 12
        }
      ],
      "created_at": "2026-06-21T05:30:00Z",
      "updated_at": "2026-06-21T05:30:00Z",
      "edited_at": null,
      "deleted_at": null,
      "recalled_at": null
    }
  }
}
```

`message.created` event 的 `payload.message` 与 ack 的 `payload.message` **同形**（同一 `projectMessageForBrowser` 投影）。前端 reducer 把 ack 与 event 视为按 `message_id` 的收敛 upsert：先收到 ack 用 `payload.message` 替换本地 pending；后收到 event frame 再 upsert 同一 `message_id`，不产生重复行；event frame 是最终 timeline 收敛来源。

协议校验失败返回 `command_error`：

```json
{
  "frame_type": "command_error",
  "command_id": "00000000-0000-7000-8000-000000000411",
  "error": {
    "code": "INVALID_MESSAGE",
    "message": "message text is empty",
    "retryable": false
  }
}
```

`command_ack` 携带提交结果（committed 语义）。event frame 仍是最终 timeline 状态。

### 6.3 编辑消息

WebSocket command frame：

```json
{
  "frame_type": "command",
  "command": "message.edit",
  "command_id": "00000000-0000-7000-8000-000000000421",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "message_id": "00000000-0000-7000-8000-000000000301",
    "text": "new text"
  }
}
```

committed_ack 携带 canonical mutation payload。注意 `command_ack.command_id` 是本次 edit 操作 id（`...0421`），而 `payload.message.command_id` 仍是原始 `message.send` 的 command id（`...0411`）——这是有意的区分：

```json
{
  "frame_type": "command_ack",
  "command": "message.edit",
  "command_id": "00000000-0000-7000-8000-000000000421",
  "status": "committed",
  "payload": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "event_id": "01J...",
    "message": {
      "message_id": "00000000-0000-7000-8000-000000000301",
      "command_id": "00000000-0000-7000-8000-000000000411",
      "channel_id": "00000000-0000-7000-8000-000000000201",
      "sender": {
        "kind": "user",
        "user": {
          "user_id": "00000000-0000-7000-8000-000000000101",
          "display_name": "Zemo",
          "avatar_url": null
        }
      },
      "type": "text",
      "format": "plain",
      "status": "edited",
      "stream_state": "none",
      "text": "new text",
      "reply_to": null,
      "reply_snapshot": null,
      "attachments": [],
      "components": [],
      "mentions": [],
      "created_at": "2026-06-21T05:30:00Z",
      "updated_at": "2026-06-21T05:31:00Z",
      "edited_at": "2026-06-21T05:31:00Z",
      "deleted_at": null,
      "recalled_at": null
    }
  }
}
```

随后广播 `message.updated` 事件，`payload.message` 与 ack 同形（`status=edited`，`edited_at` 已置，同一 `projectMessageForBrowser` 投影）。event frame 是最终 timeline 收敛来源。

### 6.4 撤回自己的消息

WebSocket command frame：

```json
{
  "frame_type": "command",
  "command": "message.recall",
  "command_id": "00000000-0000-7000-8000-000000000431",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "message_id": "00000000-0000-7000-8000-000000000301"
  }
}
```

committed_ack 携带 canonical mutation payload。撤回后 `payload.message` 为安全投影：`status=recalled`、`text=null`、`attachments=[]`、`components=[]`、`mentions=[]`，**不泄露原文 / 附件 URL / components / mentions**：

```json
{
  "frame_type": "command_ack",
  "command": "message.recall",
  "command_id": "00000000-0000-7000-8000-000000000431",
  "status": "committed",
  "payload": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "event_id": "01J...",
    "message": {
      "message_id": "00000000-0000-7000-8000-000000000301",
      "command_id": "00000000-0000-7000-8000-000000000411",
      "channel_id": "00000000-0000-7000-8000-000000000201",
      "sender": {
        "kind": "user",
        "user": {
          "user_id": "00000000-0000-7000-8000-000000000101",
          "display_name": "Zemo",
          "avatar_url": null
        }
      },
      "type": "text",
      "format": "plain",
      "status": "recalled",
      "stream_state": "none",
      "text": null,
      "reply_to": null,
      "reply_snapshot": null,
      "attachments": [],
      "components": [],
      "mentions": [],
      "created_at": "2026-06-21T05:30:00Z",
      "updated_at": "2026-06-21T05:32:00Z",
      "edited_at": null,
      "deleted_at": null,
      "recalled_at": "2026-06-21T05:32:00Z"
    }
  }
}
```

随后广播 `message.recalled` 事件，`payload.message` 与 ack 同形（同一安全投影，不泄露原文）。内部审计可保留原文，Browser API 永不返回。

### 6.5 管理员删除消息

WebSocket command frame：

```json
{
  "frame_type": "command",
  "command": "message.delete",
  "command_id": "00000000-0000-7000-8000-000000000441",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "message_id": "00000000-0000-7000-8000-000000000301",
    "reason": "spam"
  }
}
```

committed_ack 携带 canonical mutation payload。删除后 `payload.message` 为安全投影：`status=deleted`、`text=null`、`attachments=[]`、`components=[]`、`mentions=[]`，**不泄露原文 / 附件 URL / components / mentions**：

```json
{
  "frame_type": "command_ack",
  "command": "message.delete",
  "command_id": "00000000-0000-7000-8000-000000000441",
  "status": "committed",
  "payload": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "event_id": "01J...",
    "message": {
      "message_id": "00000000-0000-7000-8000-000000000301",
      "command_id": "00000000-0000-7000-8000-000000000411",
      "channel_id": "00000000-0000-7000-8000-000000000201",
      "sender": {
        "kind": "user",
        "user": {
          "user_id": "00000000-0000-7000-8000-000000000101",
          "display_name": "Zemo",
          "avatar_url": null
        }
      },
      "type": "text",
      "format": "plain",
      "status": "deleted",
      "stream_state": "none",
      "text": null,
      "reply_to": null,
      "reply_snapshot": null,
      "attachments": [],
      "components": [],
      "mentions": [],
      "created_at": "2026-06-21T05:30:00Z",
      "updated_at": "2026-06-21T05:33:00Z",
      "edited_at": null,
      "deleted_at": "2026-06-21T05:33:00Z",
      "recalled_at": null
    }
  }
}
```

随后广播 `message.deleted` 事件，`payload.message` 与 ack 同形（同一安全投影，不泄露原文）。管理员删除他人消息追加 `system.notice`（`notice_kind=message.deleted`）。内部审计可保留原文；管理员审计 API 若单独存在，可在更严格鉴权下暴露原文，但 Browser API 永不返回。

Browser API does not expose HTTP endpoints for message edit/recall/delete. Internal DO-to-DO endpoints may exist for implementation, but they are not public Browser API. 所有 message mutation 的 locator 必须是 `{channel_id, message_id}`（见 `MessageLocator`），直接路由到 `ChatChannel DO`，不存在 message-id-only 路由索引，因此消息操作永不返回 `ROUTE_INDEX_PENDING`。

### 6.6 读取消息上下文

```http
GET /api/chat/channels/{channel_id}/messages/{message_id}/context?before=30&after=30
```

Returns a timeline window around a message. Channel-scoped. Search/notification deep links must carry both `channel_id` and `message_id`. Read endpoint, remains HTTP.

### 6.7 Channel Pin

Pin 存储于 **`channel_pins` 表**（不进 `messages`）。Browser Pin UI 权威来源：`bootstrap.channel_pins` + `channel.pin.*` events + `GET .../events` gap（§10.6）。**禁止**用独立 session store 或已删除的 `stateful-session` 端点驱动顶栏。

#### 6.7.1 `channel.pin_message` / `channel.unpin_message`

Owner/admin 将 timeline 消息置顶为 `pin_kind=pinned_message`。

**可 pin 条件**：源消息 **`type=text`**（禁止 pin `image` / `sticker` / `system`）；`status` ∈ `{ normal, edited }`；`stream_state` ∈ `{ none, final }`；频道 `kind=channel`（DM → `UNSUPPORTED_CHANNEL_KIND`）。违反 → `PIN_SOURCE_INVALID`。

**`channel.pin_message`** payload：`{ "source_message_id": "…" }`。

**重复 pin ack（normative）**：

| 场景 | 行为 | `committed_ack.payload.event_id` |
|------|------|----------------------------------|
| 同 `command_id` 重试 | idempotency 缓存 | 缓存中的 `event_id` |
| 不同 `command_id`，`source_message_id` 已 pin 且无变化 | **no-op**（不发新 `channel.pin.*`） | 现有 pin 的 **`last_pin_event_id`** |
| 首次 pin 或 replace | emit `channel.pin.set` / `updated` | 新 event 的 `event_id` |

**committed_ack** payload：`{ channel_id, event_id, pin }`（`pin` 为完整 `ChannelPin`）。

**`channel.unpin_message`** payload：`{ "pin_id": "…" }` 或 `{ "source_message_id": "…" }`（二选一）。`committed_ack.payload.event_id` = `channel.pin.cleared` 的 `event_id`。

源消息 `message.updated` → `channel.pin.updated`；`message.deleted` / `message.recalled` → `channel.pin.cleared`（直接 clear，无 tombstone）。

#### 6.7.2 Bot pin effects

见 §9.7.3。开放 Bot 自建 `bot_control` / `announcement`；**不开放** Bot set/clear `session_control`。`session.effects` 允许 `set_channel_pin` / `update_channel_pin` / `clear_channel_pin`：可更新绑定当前 `session_id` 的 platform session pin（限展示字段），也可管理本会话 bot 自有的 `bot_control` / `announcement` pin。

## 7. 成员

### 7.1 获取成员列表

```http
GET /api/chat/channels/{channel_id}/members?query=ali&limit=50&cursor=opaque-cursor
```

`query` 是 display_name / user_id 的模糊搜索（前缀匹配），适合成员列表补全。**不适合按 user_id 精确读单成员资料**——精确读用 7.1b。

响应：

```json
{
  "items": [
    {
      "user": {
        "user_id": "00000000-0000-7000-8000-000000000101",
        "display_name": "alice",
        "avatar_url": null
      },
      "role": "member",
      "joined_at": "2026-06-20T12:00:00Z"
    }
  ],
  "next_cursor": null
}
```

### 7.1b 按用户 ID 读取单成员

精确读取某用户在某频道的成员资料。供前端 profile sheet（`useChatUserProfile(user_id, channel_id)`）cache miss 时按 user_id 回源，拿 `role` / `joined_at` / 离开状态。`GET /members?query=` 是模糊搜索，不能可靠按 user_id 命中，故单独提供此端点。

```http
GET /api/chat/channels/{channel_id}/members/{user_id}
```

响应（当前用户必须是该频道 active 成员；否则 403）：

```json
{
  "user": {
    "user_id": "00000000-0000-7000-8000-000000000101",
    "display_name": "alice",
    "avatar_url": null
  },
  "role": "member",
  "joined_at": "2026-06-20T12:00:00Z",
  "status": "active"
}
```

- `status`: `active` | `left`。已离开/被移除的成员仍可读（用于历史消息发送者的资料展示），但 `status` 反映其当前成员状态。
- `removed`（v2.31 delta）：**保留值，正常写路径不可达**。schema SoT 只写 `active` | `left`（owner 移除成员写入 `left`，`left_at` 记录时间）；读路径按原样投影 `channel_members.status` 列值，该保证为**写入方纪律**（列上暂无 CHECK 约束）。客户端按 `active` | `left` 处理即可；遇到 `removed` 视同 `left`。
- 用户从未加入该频道 → `404 MEMBER_NOT_FOUND`。


### 7.2 添加成员

```http
POST /api/chat/channels/{channel_id}/members
Idempotency-Key: client-key-member-add
```

请求：

```json
{
  "user_id": "00000000-0000-7000-8000-000000000101",
  "role": "member"
}
```

响应：

```json
{
  "member": {}
}
```

### 7.3 修改成员角色

```http
PATCH /api/chat/channels/{channel_id}/members/{user_id}
Idempotency-Key: client-key-member-role
```

请求：

```json
{
  "role": "admin"
}
```

响应：

```json
{
  "member": {}
}
```

### 7.4 移除成员 / 离开频道

```http
DELETE /api/chat/channels/{channel_id}/members/{user_id}
Idempotency-Key: client-key-member-remove
```

响应：

```json
{
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "user_id": "00000000-0000-7000-8000-000000000101",
  "removed": true
}
```

### 7.5 转让群主

原子地转让频道所有权。**前端不得用多个 role PATCH（§7.3）拼接"转让群主"**——会造成竞态（中间态出现零个或多个 owner）。该端点必须在服务端单事务内完成。

```http
POST /api/chat/channels/{channel_id}/owner-transfer
Idempotency-Key: <client-key>
```

请求：

```json
{
  "target_user_id": "00000000-0000-7000-8000-000000000102",
  "previous_owner_role": "admin"
}
```

`previous_owner_role` 取值：

- `admin`
- `member`

建议：前端发送 `admin`；转让后原群主成为 admin。

响应：

```json
{
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "previous_owner": {
    "user_id": "00000000-0000-7000-8000-000000000101",
    "role": "admin"
  },
  "new_owner": {
    "user_id": "00000000-0000-7000-8000-000000000102",
    "role": "owner"
  }
}
```

语义：

- 当前用户必须是该频道 active owner。
- 目标用户必须是该频道 active 成员（member/admin）。
- 频道必须 active。
- 单 owner 不变量：
  - 提交后频道内恰好存在一个 active owner。
  - 目标用户成为 owner。
  - 原群主变为 `previous_owner_role`。
- 操作必须服务端原子（单 DO 事务）。
- 服务端按需广播 role-update 事件。
- 前端以 live/replay event 为最终状态来源。

错误：

- `403 FORBIDDEN`：当前用户不是 owner。
- `404 CHANNEL_NOT_FOUND`。
- `404 MEMBER_NOT_FOUND`：目标用户不是该频道成员。
- `409 CHANNEL_DISSOLVED`。
- `409 IDEMPOTENCY_CONFLICT`。
- `422 INVALID_MEMBER_ROLE`（或既有等价 code）：目标/原角色不合法。

## 8. 附件

### 8.1 创建图片上传

```http
POST /api/chat/uploads/images/presign
Idempotency-Key: client-key-attachment-presign
```

Worker 校验当前用户、文件类型和大小，创建 pending attachment metadata，并返回 SeaweedFS（S3 兼容对象存储）的 presigned PUT URL。Worker 不接收图片二进制。

请求：

```json
{
  "filename": "image.png",
  "mime_type": "image/png",
  "size_bytes": 12345,
  "width": 512,
  "height": 512,
  "blurhash": "LFE.~f_3%D%M01V@kWM{Rj%Mt7WBt7WB"
}
```

`blurhash` 是前端从图片生成的 BlurHash 字符串（占位图编码），可选；后端保存为 attachment metadata。

响应：

```json
{
  "attachment_id": "00000000-0000-7000-8000-000000000501",
  "upload_url": "https://s3.kuma.homes/lilium-chat-attachments/chat/00000000-0000-7000-8000-000000000501?X-Amz-Signature=...",
  "upload_method": "PUT",
  "upload_headers": {
    "Content-Type": "image/png"
  },
  "expires_at": "2026-06-21T05:35:00Z"
}
```

`upload_url` 是 SeaweedFS presigned PUT，浏览器直传。presigned PUT 5 分钟过期，约束 `Content-Type` 必须与 `mime_type` 一致、`Content-Length` 上限 = `size_bytes`。

### 8.2 完成图片上传

浏览器使用 presigned URL 直传对象存储后，调用 finalize：

```http
POST /api/chat/uploads/images/{attachment_id}/finalize
Idempotency-Key: client-key-attachment-finalize
```

请求：

```json
{
  "etag": "\"object-etag\""
}
```

响应：

```json
{
  "attachment": {
    "attachment_id": "00000000-0000-7000-8000-000000000501",
    "kind": "image",
    "filename": "image.png",
    "mime_type": "image/png",
    "size_bytes": 12345,
    "width": 512,
    "height": 512,
    "blurhash": "LFE.~f_3%D%M01V@kWM{Rj%Mt7WBt7WB",
    "url": "https://s3.kuma.homes/lilium-chat-attachments/chat/00000000-0000-7000-8000-000000000501"
  }
}
```

Worker 在 finalize 时确认 pending attachment 属于当前用户，并检查对象已存在（HEAD）+ 校验 Content-Type 与 Content-Length 一致。`url` 是浏览器可直接读取的长期公开附件访问 URL。对象存储 key 不暴露给前端。

### 8.3 个人表情库

用户个人的扁平表情列表：无 pack、无市场、无频道级表情包。一个用户的库 item 由 `sticker_id` 标识。多个用户可以保存同一个 canonical image attachment。保存 sticker **不复制二进制数据**，只存引用。删除库 item 不删除历史消息、底层 attachment 对象或其他用户的库行。

**不引入** `AttachmentDirectory DO`。因此 sticker save 必须用 `{channel_id, attachment_id}` 定位源附件（`channel_id` 路由到源 `ChatChannel DO` 验证可见性并取得 canonical 投影），不接受 `message_id`，也不接受裸 `attachment_id` 作为主源定位符。若未来 API 接受裸 `attachment_id`，后端必须先引入 `AttachmentDirectory DO` 或其他全局附件定位符。

#### Sticker image projection

个人表情库复用既有 image attachment 身份。

```json
{
  "attachment_id": "00000000-0000-7000-8000-000000000501",
  "url": "https://s3.kuma.homes/lilium-chat-attachments/chat/00000000-0000-7000-8000-000000000501",
  "mime_type": "image/png",
  "width": 512,
  "height": 512,
  "size_bytes": 12345,
  "blurhash": "LFE.~f_3%D%M01V@kWM{Rj%Mt7WBt7WB"
}
```

规则：

- `attachment_id` 是 sticker 的 canonical image 身份。
- `url` 是该 `attachment_id` 的 Browser-visible 稳定图片 URL。
- 同一 sticker 反复发送必须投影同一 `attachment_id` 和同一图片 URL。
- 不引入单独的 `asset_id`。

#### PersonalSticker model

```json
{
  "sticker_id": "00000000-0000-7000-8000-000000000901",
  "attachment": {
    "attachment_id": "00000000-0000-7000-8000-000000000501",
    "url": "https://s3.kuma.homes/lilium-chat-attachments/chat/00000000-0000-7000-8000-000000000501",
    "mime_type": "image/png",
    "width": 512,
    "height": 512,
    "size_bytes": 12345,
    "blurhash": "LFE.~f_3%D%M01V@kWM{Rj%Mt7WBt7WB"
  },
  "created_at": "2026-06-25T00:00:00Z"
}
```

- `sticker_id` 是当前用户的个人库 item id，**跨用户不稳定**。
- `attachment.attachment_id` 是可复用的 canonical image id，可跨用户的个人表情库共享。

#### 列表

```http
GET /api/chat/stickers?limit=100&cursor=opaque
```

响应：

```json
{
  "items": [],
  "next_cursor": null
}
```

语义：

- 只返回当前用户的个人表情库。
- 默认排序：`created_at DESC`。
- 服务端限制 `limit` 上限。
- 已删除的库 item 不返回。
- 每个 item 返回 `sticker_id` + canonical `attachment` 投影。

#### 保存

```http
POST /api/chat/stickers
Idempotency-Key: <client-key>
```

请求：

```json
{
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "attachment_id": "00000000-0000-7000-8000-000000000501"
}
```

规则：

- `channel_id` 必填：后端据此路由到源 `ChatChannel DO` 验证可见性并取得 canonical attachment 投影。
- `attachment_id` 必填：即使一条消息含多个附件，也能唯一定位所选图片。
- `message_id` **不**要求，且不得作为主源定位符。
- 不引入 `AttachmentDirectory DO`（见本节开头说明）。

响应：

```json
{
  "sticker": {}
}
```

语义：

- `attachment_id` 必须标识一个已 finalize 的 image attachment。
- 当前用户必须能通过 `channel_id` 内一条可见的普通 image/sticker 消息看到该附件，或按既有附件规则拥有该 finalized attachment。
- Deleted/recalled 消息的附件不得通过 Browser API 保存为 sticker。
- 保存不复制二进制对象。
- 保存只创建或返回当前用户的个人库 item（引用 canonical `attachment_id`）。
- 同一用户重复保存同一 `attachment_id` 返回既有 sticker 或幂等等价结果。
- 不写 channel timeline event。
- 不改变原消息。

#### 删除

```http
DELETE /api/chat/stickers/{sticker_id}
Idempotency-Key: <client-key>
```

响应：

```json
{
  "sticker_id": "00000000-0000-7000-8000-000000000901",
  "deleted": true
}
```

语义：

- 只删除当前用户的库 item。
- 不删除 canonical attachment。
- 不影响历史 sticker 消息。
- 不影响其他用户保存的 sticker。
- 重复删除返回幂等等价结果。

## 9. Bot

本文不设计完整 bot 市场；API 必须支持官方 bot 作为外置 bot app 接入。

Bot API 与 Browser API 分离：

- Browser API 使用 ToolBear browser JWT，走 Browser WS `/api/chat/ws` → `UserConnection DO(user_id)`。
- Bot API 使用 bot token。
- Bot runtime delivery 走 **Bot Gateway WebSocket RPC**：bot 主动 outbound 连 `/api/chat/bot/ws`（bot token 鉴权）→ `BotConnection DO(bot_id)`，Chat 向 bot 推 `delivery` 帧（`command_invocation` / `message_interaction` / `message_event`），bot 回 `delivery_result`（含 effects），Chat 回 `delivery_ack`。
- Bot catalog 同步走 outbound HTTP：`PUT /api/chat/bot/commands`（bot → Chat 的 HTTP，**不要求 bot 暴露 HTTP endpoint**）。
- Bot **消息 mutation**（发消息、改消息、流式、components）**只**走 Bot Gateway WS 的 `delivery_result.effects` / `session.effects`；**无** Bot HTTP 发消息端点。
- HTTP callback（Chat → bot HTTP `POST <bot_callback_url>` + HMAC 签名）为 **future transport**，不实现。
- 官方 bot 和第三方 bot 走同一套 token、installation、command、effect 机制。

### 9.1 Bot token 认证

```http
Authorization: Bearer <bot_token>
```

Bot token 原文只返回一次，服务端只存 hash。

Bot token scope：

- `chat:messages:write`
- `chat:messages:read`
- `chat:commands:manage`
- `chat:channels:read`
- `chat:members:read`
- `chat:runtime:connect` — 连接 Bot Gateway WS（`GET /api/chat/bot/ws`），接收 runtime delivery

`GET /api/chat/bot/ws` 必须有 `chat:runtime:connect` scope。`PUT /api/chat/bot/commands` 需 `chat:commands:manage`。`chat:messages:write` 用于 Bot Gateway WS 上 `delivery_result` / `session.effects` 中的发消息类 effect。

### 9.2 Bot actor

Bot 发送的消息必须有独立 actor，不伪装成普通用户。

```json
{
  "bot_id": "00000000-0000-7000-8000-000000000601",
  "display_name": "Lilium Bot",
  "avatar_url": "https://example.com/bot.png"
}
```

Message sender 支持两种形状：

```json
{
  "kind": "user",
  "user": {
    "user_id": "00000000-0000-7000-8000-000000000101",
    "display_name": "alice",
    "avatar_url": null
  }
}
```

```json
{
  "kind": "bot",
  "bot": {
    "bot_id": "00000000-0000-7000-8000-000000000601",
    "display_name": "Lilium Bot",
    "avatar_url": null
  }
}
```

Bot actor 的 display_name / avatar_url 来自 BotRegistry（chat 自有数据），不查 ToolBear profile。Browser UI 必须按 `kind` 渲染，不得把 bot id 当用户 id 展示。

**Platform bot（内置 `/help`）**：平台命令不经过 BotRegistry，使用固定 well-known identity：

| 字段 | 值 |
|---|---|
| `bot_id` | `00000000-0000-7000-8000-000000000600` |
| `display_name` | `system` |
| `avatar_url` | `https://s3.kuma.homes/chat/avatars/019f134b-4324-7300-9023-b092c06ac4b2.png` |
| `/help` 的 `bot_command_id` | `00000000-0000-7000-8000-000000000700` |
| `/permission` 的 `bot_command_id` | `00000000-0000-7000-8000-000000000708` |

`/help` / `/permission` 响应以 `format=unsafe-markdown` 的 bot text message 写入频道 timeline（§3.9）；`messages` 行持久化 `sender_bot_display_name` / `sender_bot_avatar_url` 与 `format`，Browser 投影原样读取（不查 BotRegistry）。

### 9.3 注册 slash command

```http
PUT /api/chat/bot/commands
Authorization: Bearer <bot_token>
Idempotency-Key: client-key-bot-command-sync
```

请求：

```json
{
  "commands": [
    {
      "name": "ask",
      "aliases": ["ai", "chat"],
      "description": "Ask the assistant",
      "help_text": "用法: /ask <prompt>\n向助手提问。",
      "options": [
        {
          "name": "prompt",
          "type": "string",
          "required": true,
          "description": "Question"
        }
      ],
      "default_member_permission": "member",
      "execution": {
        "mode": "stateless"
      }
    }
  ]
}
```

`PUT /bot/commands` only syncs the **global bot command catalog** (BotRegistry)。它 **不 enable 任何频道的 command** —— channel 内是否可用由 per-channel allow/block binding（`PATCH /channels/{channel_id}/commands/{bot_command_id}`）及 official bot 全局 auto-allow 规则决定。

字段：

- `commands[].aliases`: 同一 `bot_command_id` 的 alternate slash triggers；`command.invoke` 用 `bot_command_id`，payload 带 `invoked_name`（见 §9.5）。
- `commands[].help_text`: 单命令详细帮助文本；`/help <command>` 命中时返回此字段（fallback 为 `description`）。
- `commands[].default_member_permission`: 默认 `member`/`admin`/`owner`；channel binding 可用 `permission_override` 覆盖。
- `commands[].execution`: `mode` 为 `stateless` | `stateful`；`stateful` 时带 mutex/TTL/listen_capability。
- 全局 slash namespace：`bot_command_names` 在 BotRegistry；sync 时名称冲突 → `409 COMMAND_NAME_CONFLICT`。

响应：

```json
{
  "commands": [
    {
      "bot_command_id": "00000000-0000-7000-8000-000000000701",
      "name": "ask",
      "aliases": ["ai", "chat"],
      "status": "active",
      "execution_mode": "stateless",
      "stateful_config": null,
      "definition_hash": "sha256:...",
      "schema_version": 1,
      "updated_at": "2026-06-21T05:30:00Z"
    }
  ]
}
```

**Official bot commands**：`visibility: "official"` 的 bot 其 catalog 中 `status=active` 的命令在**所有非 DM 频道**自动可用，无需 allow binding。频道管理员只能 `blocked` 显式禁用；对 official command 发 `status: "allowed"` → `409 OFFICIAL_COMMAND_AUTO_ALLOWED`。非 official bot 仍须 allow binding 后才出现在 manifest。

同一频道内 allowed command 名称不能冲突（`channel_command_names`）；bot slash command 定义 id 字段名为 `bot_command_id`（与 Browser WS frame 的 `command_id` = durable operation id 区分）。

slash command option 类型：

- `string`: 普通文本。
- `integer`: 整数，支持 `min` 和 `max`。
- `number`: 小数，支持 `min` 和 `max`。
- `boolean`: 布尔值。
- `user`: 当前频道成员 user ID，前端使用成员列表补全。
- `channel`: 当前用户可见 channel ID，前端使用频道列表补全。
- `role`: 频道角色，值为 `owner`、`admin`、`member`。

前端按 `type` 渲染输入控件和补全。Worker 在执行 `command.invoke` 前按注册 schema 校验 required、type、range、可见性和成员关系。

### 9.4 查询频道可用命令

Browser API：

```http
GET /api/chat/channels/{channel_id}/commands
```

响应（完整 manifest；`?prefix=` 已废弃，传入则忽略）：

```json
{
  "version": 3,
  "items": [
    {
      "bot_command_id": "00000000-0000-7000-8000-000000000701",
      "name": "summarize",
      "aliases": ["sum", "tl_dr"],
      "description": "Summarize recent messages",
      "help_text": "用法: /summarize\n总结最近消息。",
      "bot": {
        "bot_id": "00000000-0000-7000-8000-000000000601",
        "display_name": "Lilium Bot",
        "avatar_url": null
      },
      "options": [],
      "effective_member_permission": "member",
      "execution": { "mode": "stateless" }
    },
    {
      "bot_command_id": "00000000-0000-7000-8000-000000000700",
      "name": "help",
      "aliases": [],
      "description": "查看可用命令",
      "help_text": "",
      "bot": {
        "bot_id": "00000000-0000-7000-8000-000000000600",
        "display_name": "system",
        "avatar_url": "https://s3.kuma.homes/chat/avatars/019f134b-4324-7300-9023-b092c06ac4b2.png"
      },
      "options": [
        { "name": "command", "type": "string", "required": false, "description": "命令名" }
      ],
      "effective_member_permission": "member",
      "execution": { "mode": "stateless" }
    }
  ]
}
```

字段与规则：

- `version`: 频道 manifest 单调版本；binding 变更通过 `command.binding_updated` 事件携带 `command_manifest_delta`。
- `items[]`: 当前 caller 在该频道可见的全部 allowed commands（含 official auto-allowed + 显式 allowed binding + platform `/help`）。
- `help_text`: 来自 binding snapshot 或 official catalog；platform `/help` 固定为空字符串。
- `effective_member_permission`: `permission_override ?? default_member_permission`；caller role 不足的项被过滤。
- `bot`: 来自 binding snapshot 或 official catalog；platform `/help` 使用 §9.2 platform bot identity。
- **Official auto-allow**：`visibility: "official"` bot 的 active catalog 命令自动并入 manifest，除非该频道存在 `status: "blocked"` binding。
- **Platform `/help`**：服务端始终 append 到 manifest（`bot_command_id` = `00000000-0000-7000-8000-000000000700`），不占 binding 行。
- DM 频道：返回 `{ "version": 0, "items": [] }`（无 `/help`）。
- Bootstrap `command_manifest` 与 `GET .../commands` 同形。

`GET .../commands` 是 read cache（binding snapshot + official merge）；`command.invoke` 的 correctness source 是当前 BotRegistry catalog + official catalog fallback（见 §9.5）。

### 9.5 调用 slash command

WebSocket command frame（payload 用 `bot_command_id`；`command_id` 为 durable 幂等键；payload 可带 `invoked_name`）：

```json
{
  "frame_type": "command",
  "command": "command.invoke",
  "command_id": "00000000-0000-7000-8000-000000000812",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "bot_command_id": "00000000-0000-7000-8000-000000000701",
    "invoked_name": "sum",
    "options": {
      "prompt": {
        "type": "string",
        "value": "hello"
      },
      "target": {
        "type": "user",
        "value": "00000000-0000-7000-8000-000000000101"
      },
      "count": {
        "type": "integer",
        "value": 3
      },
      "channel": {
        "type": "channel",
        "value": "00000000-0000-7000-8000-000000000201"
      }
    }
  }
}
```

`invoked_name` 规则：

- `invoked_name` 可选。如存在，必须是该 channel `channel_command_names` 中此 `bot_command_id` 的 canonical name 或 alias；不存在或不属于该 command → `COMMAND_NOT_FOUND`。
- 如省略，服务端按 canonical name 处理。
- `invoked_name` 参与 `request_hash` 计算（幂等冲突检测）：同 `command_id` + 异 `invoked_name` → `IDEMPOTENCY_CONFLICT`。
- `command.invoke` correctness source 是当前 BotRegistry catalog（非 channel binding snapshot）：服务端 fetch 当前 `bot_commands` 行校验，disabled/deleted → `BOT_COMMAND_DISABLED`，`definition_hash` drift 用当前定义校验 options 并刷新 binding snapshot。
- bot offline precheck：bot 未连接 Bot Gateway WS → `command_error` `BOT_OFFLINE`（`retryable=true`），不持久化 invocation。

**Platform `/help` 特例**：`bot_command_id` = `00000000-0000-7000-8000-000000000700` 时：

- 不经过 Bot Gateway delivery；服务端同步写入一条 bot text message（`sender_kind: "bot"`，`format: "markdown"`，platform bot identity，见 §9.2）。
- 无 `command.invoked` pending 态；`command_invocations.status` 直接 `completed`。
- `committed_ack.payload` 含 `message_id`、`event_id` 及完整 Browser-visible `message` 投影（同 `message.send` ack 形状）。
- 无 `options.command` 时列出当前 caller manifest **全部**命令（按 `bot.display_name` 分组），**包含** platform `/help`；若 caller 为 owner/admin 且 manifest 含 `/permission` 则一并列出。每条命令使用 §3.9 slash command chip 格式：`` [`/name`](/command:name) — description ``。
- 有 `options.command` 时返回该命令的 `help_text`（fallback `description`），未知命令返回 `未知命令: <name>` 纯文本（无 chip）。

Worker 接受 command 并在事务提交后返回 committed_ack（ack payload-bearing；`command_id` 为 durable 幂等键）：

```json
{
  "frame_type": "command_ack",
  "command": "command.invoke",
  "command_id": "00000000-0000-7000-8000-000000000812",
  "status": "committed",
  "payload": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "invocation_id": "00000000-0000-7000-8000-000000000811",
    "event_id": "01J..."
  }
}
```

随后广播（以下为 **Browser wire projection**；storage 字段见 §9.6.2）：

```json
{
  "frame_type": "event",
  "event_id": "01J...",
  "type": "command.invoked",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "occurred_at": "2026-06-21T05:30:00Z",
  "payload": {
    "invocation": {
      "invocation_id": "00000000-0000-7000-8000-000000000811",
      "status": "pending",
      "created_at": "2026-06-21T05:30:00Z"
    },
    "command_id": "00000000-0000-7000-8000-000000000812",
    "command_name": "werewolf",
    "actor": {
      "user_id": "00000000-0000-7000-8000-000000000101",
      "display_name": "alice",
      "avatar_url": null
    }
  }
}
```

`command_name` 为 Browser 展示用 slash 名：优先 `invoked_name`（alias 命中时），否则 canonical `command_name`。`actor` 为调用者 UserSummary，live broadcast 与 HTTP replay 均由 `actor_user_id` 实时 resolve（§9.6.2）。

Slash command 是 command invocation，不是普通 text message。前端输入以 `/` 开头并选中命令后必须发送 `command.invoke` frame。

### 9.6 提交 rich UI interaction

WebSocket command frame（`command_id` 为 durable 幂等键）：

```json
{
  "frame_type": "command",
  "command": "interaction.submit",
  "command_id": "00000000-0000-7000-8000-000000000a31",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "message_id": "00000000-0000-7000-8000-000000000301",
    "component_id": "00000000-0000-7000-8000-000000000a01",
    "custom_id": "confirm",
    "value": true
  }
}
```

select command：

```json
{
  "frame_type": "command",
  "command": "interaction.submit",
  "command_id": "00000000-0000-7000-8000-000000000a32",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "message_id": "00000000-0000-7000-8000-000000000301",
    "component_id": "00000000-0000-7000-8000-000000000a02",
    "custom_id": "pick_item",
    "value": "sword"
  }
}
```

Worker 接受 command 并在事务提交后返回 committed_ack（ack payload-bearing；`command_id` 为 durable 幂等键）：

```json
{
  "frame_type": "command_ack",
  "command": "interaction.submit",
  "command_id": "00000000-0000-7000-8000-000000000a31",
  "status": "committed",
  "payload": {
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "interaction_id": "00000000-0000-7000-8000-000000000a41",
    "event_id": "01J..."
  }
}
```

随后广播事件（以下为 **Browser wire projection**；storage 字段见 §9.6.2）：

```json
{
  "frame_type": "event",
  "event_id": "01J...",
  "type": "interaction.created",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "occurred_at": "2026-06-21T05:30:00Z",
  "payload": {
    "interaction": {
      "interaction_id": "00000000-0000-7000-8000-000000000a21",
      "status": "pending",
      "created_at": "2026-06-21T05:30:00Z"
    },
    "command_id": "00000000-0000-7000-8000-000000000a31",
    "component_label": "确认",
    "actor": {
      "user_id": "00000000-0000-7000-8000-000000000101",
      "display_name": "alice",
      "avatar_url": null
    }
  }
}
```

`component_label` 取自目标 message 当前 `components_json` 中匹配 `component_id` 的 `label` 字段（button/select 等）；replay 时按当前 message 状态重新 resolve。`actor` 为提交者 UserSummary。

Worker 校验当前用户能看见该消息、消息来自 Bot、component 未 disabled、`custom_id` 与持久化组件一致、**`interaction_policy` 门禁通过**（§3.8）、**`value` 形状与 `kind` 匹配**（见下表）。前端不解析 `custom_id`，只原样提交。

**`payload.value` 类型：**

| component `kind` | `value` 类型 | Worker 额外校验 |
|---|---|---|
| `button` | `boolean`（恒 `true`） | — |
| `select` / `radio` | `string` | 必须命中 `options[].value` |
| `checkbox` | `boolean` | — |
| `checkbox_group` | `string[]` | 每项命中 `options[].value`；长度 ∈ `[min_selected, max_selected]` |
| `text_input` | `string` | 长度 ∈ `[min_length, max_length]` |

**平台 / Bot 职责：**

- **平台（Chat）**：per-channel 有序 `event_id`；`interaction.created` / `interaction.completed` / `message.updated`（`exclusive` 锁控件）进同一 timeline；`message_interaction` delivery 顺序与同 channel 已 committed interaction 顺序一致（at-least-once delivery，Bot 用 `delivery_id` + effect 幂等去重）；`interaction_policy` 在 submit 事务内执行。
- **Bot**：收到 delivery 后处理业务语义（谁该得奖励、状态如何变）；`multi` policy 下可能收到并发 delivery，Bot 自行 dedupe；`disable_components` / `update_message` 用于 Bot 主动更新 UI，非 primary 互斥手段（`exclusive` 已由平台锁死）。

**delivery 顺序不变量：** 同一 `channel_id` 内，Bot 经 `message_interaction` delivery 收到的 interaction，其 `interaction_id` 对应 committed 顺序与频道 `interaction.created` event 顺序一致。Bot 应按 delivery 到达顺序处理；重试 delivery 不改变已应用的业务结果（effect / interaction lifecycle 幂等）。

#### 9.6.1 Interaction delivery 完成

`interaction.submit` committed 后，Chat 写入 `bot_delivery_outbox(kind=message_interaction)` 并向 Bot Gateway 异步 delivery。Bot 回 `delivery_result`（含 `effects`，可为空数组）后，ChatChannel 在同一 `message_interaction` outbox 行上完成 interaction lifecycle：

| 结果 | `interactions.status` | timeline event |
|---|---|---|
| `delivery_result` 成功应用（含 `effects: []`） | `completed` | `interaction.completed` |
| effect 校验/应用失败（如 `BOT_EFFECT_INVALID`） | `failed` | `interaction.failed` |
| 已 `completed` / `failed`（幂等重放） | 不变 | 不重复 emit |

`interaction.completed` 为 **content-bearing** event：`payload.message` 为完整 Browser-visible Message 投影（与 §6.2 `message.*` event 同形，含当前 `components`），关联被交互的 bot message（`interaction.message_id`）。`payload.command_id` 等于 submit 时的 durable `command_id`（≡ `operation_id`）。

```json
{
  "frame_type": "event",
  "event_id": "01J...",
  "type": "interaction.completed",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "occurred_at": "2026-06-21T05:30:05Z",
  "payload": {
    "command_id": "00000000-0000-7000-8000-000000000a31",
    "channel_id": "00000000-0000-7000-8000-000000000201",
    "event_id": "01J...",
    "message": {
      "message_id": "00000000-0000-7000-8000-000000000301",
      "channel_id": "00000000-0000-7000-8000-000000000201",
      "sender": { "kind": "bot", "bot": { "bot_id": "...", "display_name": "...", "avatar_url": null } },
      "type": "text",
      "format": "plain",
      "status": "normal",
      "stream_state": "none",
      "text": "Pick one",
      "components": [],
      "mentions": [],
      "attachments": [],
      "created_at": "2026-06-21T05:29:00Z",
      "updated_at": "2026-06-21T05:30:05Z",
      "edited_at": null,
      "deleted_at": null,
      "recalled_at": null
    }
  }
}
```

`interaction.failed` payload：

```json
{
  "frame_type": "event",
  "event_id": "01J...",
  "type": "interaction.failed",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "occurred_at": "2026-06-21T05:30:05Z",
  "payload": {
    "command_id": "00000000-0000-7000-8000-000000000a31",
    "error_code": "BOT_EFFECT_INVALID",
    "error_message": "invalid effect",
    "retryable": false
  }
}
```

Bot 可在 `delivery_result.effects` 中返回 `send_message` / `update_message` / `disable_components` 表达交互结果；这些 effect 与 `interaction.completed` **同一 delivery 处理路径**内应用，随后 emit `interaction.completed`（message 投影反映 effect 应用后的当前状态）。`exclusive` policy 的 component 锁定仍在 `interaction.submit` 事务内由平台完成（`message.updated`），不等待 bot delivery。

#### 9.6.2 Bot runtime lifecycle storage vs wire projection

以下 payload 为 **Browser projection**（live broadcast + HTTP `GET .../events` replay）。`events.payload_json`（DO storage）**不持久化 UserSummary** 或 component label 文案，只存引用字段；输出时实时 resolve（与 `system.notice` §10.4 规则一致）。

| event type | storage（`payload_json`） | wire 额外字段（输出时 resolve） |
|---|---|---|
| `command.invoked` | `invocation`（id/status/created_at）、`command_id`、`actor_user_id`、`command_name`、`invoked_name` | `actor` UserSummary；`command_name` = `invoked_name` 非空时取 alias/canonical 展示名，否则 canonical `command_name` |
| `interaction.created` | `interaction`（id/status/created_at）、`command_id`、`actor_user_id`、`message_id`、`component_id` | `actor` UserSummary；`component_label` 从 `message_id` 当前 `components_json` 解析 |
| `interaction.completed` | `command_id`、`message` 消息引用字段（同 `message.*` persisted shape，无 UserSummary） | `message` 完整 Browser 投影（含 components）；replay 按当前 `message.status` 过滤（§10.3） |
| `interaction.failed` | `command_id`、`error_code`、`error_message`、`retryable` | 同 storage（无 UserSummary 字段） |

实现时切勿把 `display_name` / `avatar_url` / `component_label` 落进 DO storage。

#### 9.6.3 Pin locator 与 `platform:` 命名空间

`interaction.submit` payload **必须**满足 **exactly one of** `message_id` / `pin_id`：

| 条件 | 结果 |
|------|------|
| 两者皆无 | `INVALID_MESSAGE` |
| 两者皆有 | `INVALID_MESSAGE` |
| 仅 `message_id` | 现有 timeline 路径（查 `messages` 表） |
| 仅 `pin_id` | Pin 路径（查 `channel_pins` 表） |

**Pin 路径 payload 示例**：

```json
{
  "frame_type": "command",
  "command": "interaction.submit",
  "command_id": "00000000-0000-7000-8000-000000000d01",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "payload": {
    "pin_id": "00000000-0000-7000-8000-00000000a01",
    "component_id": "00000000-0000-7000-8000-000000000c01",
    "custom_id": "platform:stop_session",
    "value": true
  }
}
```

解析顺序：校验 locator 互斥 → 若 `pin_id`：从 `channel_pins` 取 pin → 校验 `component_id` / `custom_id` / `interaction_policy` → 若 `custom_id` 以 `platform:` 开头：**平台短路**（不要求 Bot 在线，不写 `bot_delivery_outbox`）→ 否则按 `pin_owner_kind` 路由 Bot `message_interaction` delivery。

- `custom_id` 前缀 **`platform:`** 为 **平台保留**。
- Bot 在 `send_message` / `update_message` / pin effects 中 **`不得`** 使用 `platform:` 前缀；校验失败 → `BOT_EFFECT_INVALID`。
- 仅 **platform-owned** pin 可使用 `platform:*` 并走平台短路。

#### 9.6.4 `PlatformPinInteractionAck`（`platform:stop_session`）

平台短路 **不写** synthetic `interaction` 行；**无** `interaction_id` / `interaction.completed` / `interaction.failed`。

**`platform:stop_session` 流程**：校验 starter \| owner \| admin → `session.status = closing` → 同事务 `channel.pin.updated`（禁用 Stop）→ `committed_ack` → 异步 `session.stop_requested`（§9.7.4）→ 等待 Bot `session.close`；超时强停 → `channel.pin.cleared` + `stateful_session.closed`。

**committed_ack**（`PlatformPinInteractionAck`）：

```json
{
  "frame_type": "command_ack",
  "command": "interaction.submit",
  "command_id": "…",
  "status": "committed",
  "payload": {
    "channel_id": "…",
    "event_id": "01J…",
    "pin_id": "…",
    "session_id": "…",
    "custom_id": "platform:stop_session"
  }
}
```

`payload.event_id` = 本次 `channel.pin.updated`（进入 `closing`）的 `event_id`。重复点击（已 `closing`）→ `SESSION_STOP_IN_PROGRESS`（`command_error`）。

Timeline `interaction.submit`（`message_id` locator）committed_ack 含 `interaction_id` + `event_id`（§9.6 示例）；与平台短路 ack **不同形**。

### 9.7 Bot Gateway WebSocket RPC

Bot runtime delivery 的唯一 transport 是 Bot Gateway WebSocket RPC。Bot 主动向 Chat 发起 outbound WebSocket，Chat 通过该 WS 向 bot 下发 runtime delivery，bot 回 `delivery_result`（含 effects），Chat 回 `delivery_ack`。HTTP callback（`POST <bot_callback_url>` + HMAC 签名）为 future transport，不实现。

```http
GET wss://chat.kuma.homes/api/chat/bot/ws
Authorization: Bearer <bot_token>
Sec-WebSocket-Protocol: lilium.chat.bot.v1
```

语义：

- Bot 主动发起 outbound WebSocket 连接到 Chat API。
- Worker 通过 singleton BotRegistry 验证 bot token（SHA-256 hash → `bot_tokens.token_hash`）。
- Worker 将 accepted socket 路由到 `BotConnection DO(bot_id)`。
- `BotConnection` 持有 bot runtime 连接状态 + delivery 队列。
- Runtime delivery 由 Chat 经此 WS 推送给 bot（server → bot 方向）。
- Bot 回 `delivery_result` 帧（含 effects），Chat 侧校验并应用 effects，写入 `ChatChannel` timeline。
- HTTP callback（Chat → bot HTTP `POST <bot_callback_url>` + HMAC 签名）为 **future transport**，不实现。

不要让 bot 复用 Browser WS。Browser WS 仍是 `/api/chat/ws` + ToolBear browser JWT + `UserConnection DO(user_id)`；Bot 专用 WS 是 `/api/chat/bot/ws` + bot token + `BotConnection DO(bot_id)`。

#### 9.7.1 帧协议

Bot 建连后发 `hello`：

```json
{
  "type": "hello",
  "api_version": "lilium.chat.bot.v1",
  "last_received_delivery_id": null
}
```

Server 回 `ready`：

```json
{
  "type": "ready",
  "api_version": "lilium.chat.bot.v1",
  "bot_id": "00000000-0000-7000-8000-000000000601",
  "session_id": "00000000-0000-7000-8000-000000000901",
  "server_time": "2026-06-26T00:00:00Z"
}
```

Server 下发 command invocation：

```json
{
  "type": "delivery",
  "api_version": "lilium.chat.bot.v1",
  "delivery_id": "01J...",
  "kind": "command_invocation",
  "invocation_id": "00000000-0000-7000-8000-000000000811",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "command": {
    "bot_command_id": "00000000-0000-7000-8000-000000000701",
    "name": "ask",
    "invoked_name": "ask",
    "schema_version": 3,
    "definition_hash": "sha256:...",
    "options": {}
  },
  "invoker": {
    "user_id": "00000000-0000-7000-8000-000000000101",
    "display_name": "alice",
    "avatar_url": null
  }
}
```

Server 下发 rich UI interaction：

```json
{
  "type": "delivery",
  "api_version": "lilium.chat.bot.v1",
  "delivery_id": "01J...",
  "kind": "message_interaction",
  "interaction_id": "00000000-0000-7000-8000-000000000a21",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "message_id": "00000000-0000-7000-8000-000000000301",
  "component": {
    "component_id": "00000000-0000-7000-8000-000000000a01",
    "custom_id": "confirm",
    "value": true
  },
  "actor": {
    "user_id": "00000000-0000-7000-8000-000000000101",
    "display_name": "alice",
    "avatar_url": null
  }
}
```

Server 下发 passive message event（§9.9 stateful `listen_capability` 触发）。`message` 为完整 Browser-visible Message 投影（§3.4），`sender` 按消息来源取 user 或 bot 形状（loop prevention 默认排除 bot 自己的消息，故 bot listener 通常收到的是 user sender）：

```json
{
  "type": "delivery",
  "api_version": "lilium.chat.bot.v1",
  "delivery_id": "01J...",
  "kind": "message_event",
  "event": {
    "event_id": "01J...",
    "type": "message.created",
    "occurred_at": "2026-06-26T00:00:00Z"
  },
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "message": {
    "message_id": "00000000-0000-7000-8000-000000000301",
    "sender": {
      "kind": "user",
      "user": {
        "user_id": "00000000-0000-7000-8000-000000000101",
        "display_name": "alice",
        "avatar_url": null
      }
    },
    "type": "text",
    "format": "plain",
    "status": "normal",
    "text": "hello",
    "attachments": [],
    "components": [],
    "mentions": [],
    "created_at": "2026-06-26T00:00:00Z"
  }
}
```

若 sender 是 bot（如未设 `include_bot_messages=true` 且非订阅 bot 自己，但仍可能收到其它 bot 的消息），`sender` 形状为：

```json
"sender": {
  "kind": "bot",
  "bot": {
    "bot_id": "00000000-0000-7000-8000-000000000602",
    "display_name": "Other Bot",
    "avatar_url": null
  }
}
```

Bot 回 `delivery_result`：

```json
{
  "type": "delivery_result",
  "api_version": "lilium.chat.bot.v1",
  "delivery_id": "01J...",
  "status": "ok",
  "effects": [
    {
      "type": "send_message",
      "client_effect_id": "00000000-0000-7000-8000-000000000901",
      "message": {
        "type": "text",
        "format": "markdown",
        "text": "bot response",
        "reply_to_message_id": null,
        "attachment_ids": [],
        "components": []
      }
    }
  ]
}
```

`message_event` delivery：bot 通常不带 effects（observer/responder only），可回空 `effects: []`；若 bot 要响应，按同 effect 协议返回（effects 走 `command_invocation`/`message_interaction` 相同的应用管线）。

Server 应用 effects 后回 `delivery_ack`：

```json
{
  "type": "delivery_ack",
  "api_version": "lilium.chat.bot.v1",
  "delivery_id": "01J...",
  "status": "applied"
}
```

失败 ack：

```json
{
  "type": "delivery_ack",
  "api_version": "lilium.chat.bot.v1",
  "delivery_id": "01J...",
  "status": "failed",
  "error": {
    "code": "BOT_EFFECT_INVALID",
    "message": "..."
  }
}
```

规则：

- `delivery_id` 是 server 生成的 durable delivery id。
- Bot 必须把 delivery 视为 **at-least-once**，按 `delivery_id` 去重。
- Effects 按 `(channel_id, bot_id, client_effect_id)` 幂等。
- Server 可在 reconnect 后 redeliver 已发送但未完成 `delivery_result`/`delivery_ack` 的 delivery。
- Bot 可对同一 `delivery_id` 重发 `delivery_result`。
- 同一 `client_effect_id` 配不同 body → `BOT_EFFECT_CONFLICT`。
- `BotConnection` lease 到期时，server **主动关闭** bot WS（close reason: `lease_expired`）；bot 需重连并从 `ready` 后继续消费 redelivery。

#### 9.7.2 Bot offline policy

首版 policy：

- `command_invocation`：command.invoke precheck 时 bot 离线 → `command_error` `BOT_OFFLINE`；invocation 已 commit 但 delivery 前 bot 断连 → 短 TTL 后 invocation 标 failed。
- `message_interaction`：interaction.submit precheck 时 bot 离线 → `command_error` `BOT_OFFLINE`；interaction 已 commit 但 delivery 前 bot 断连 → 短 TTL 后 interaction 标 failed。
- `message_event`：bot 离线时 drop / expire，不产生用户可见错误；不批量重放历史 passive event。

#### 9.7.3 Effects

> 主 Bot Gateway WS（§9.7）仅接受非流式 effect + `start_stream`；流式 append/finalize 走专用 Stream WS（§9.15）。实现不变量见 §12.4。

Bot `delivery_result` / `session.effects` 在主 Bot Gateway WS 上可返回的 effect：

- `send_message`: 发送 **非 stream** Bot 消息（canonical `stream_state=none`）；可含 `components`（§3.8）。`message.format` 见 §3.9.1。
- `update_message`: 更新 Bot 自己发送的消息文本、附件和 components（目标消息须 `stream_state=none`）。
- `disable_components`: 禁用 Bot 自己发送的消息组件（目标消息须 `stream_state=none`）。
- `start_stream`: 创建 streaming registry + 返回 Stream WS URL（**不**写入 canonical `messages`；**禁止** `components`；`message.format` 见 §3.9.1；详见 §9.13–§9.14）。
- `set_channel_pin` / `update_channel_pin` / `clear_channel_pin`（§6.7.2）：`message` 为 `PinMessageDraft` / `PinMessagePatch`（§3.10.2）；`pin_kind` 仅 `bot_control` | `announcement`（set）；Bot **不得** set/clear `session_control`。`session.effects` 允许上述三种 pin effect：可更新 platform session pin，也可管理 bot 自有的 `bot_control` / `announcement` pin（与 session pin 并存）。`delivery_ack.effect_results[]` 可含 `{ client_effect_id, type, status, pin_id, event_id }`。

主 Bot Gateway WS **拒绝**：

- `append_stream` → `BOT_EFFECT_INVALID`（recovery hint 可含 `stream.ws_url`）
- `finalize_stream` → `BOT_EFFECT_INVALID`

`delivery_ack` 对成功应用的 effect 可携带 `effect_results[]`（§9.14）；`start_stream` **必须**返回 `{ message_id, stream: { channel_id, message_id, ws_url, expires_at } }`。

非流式 effect 示例：

```json
{
  "effects": [
    {
      "type": "send_message",
      "client_effect_id": "00000000-0000-7000-8000-000000000910",
      "message": {
        "type": "text",
        "format": "markdown",
        "text": "bot response",
        "reply_to_message_id": null,
        "attachment_ids": [],
        "components": []
      }
    }
  ]
}
```

Chat 按 `(channel_id, bot_id, client_effect_id)` 对 effects 做幂等。同一 `client_effect_id` 配不同 body → `BOT_EFFECT_CONFLICT`。

`message.format` 允许 `plain` | `markdown` | `unsafe-markdown`；`unsafe-markdown` 仅 official bot 可用（BotConnection `delivery_result` 拦截，§3.9.1）。非法 format 字符串 → ChatChannel `422 BOT_EFFECT_INVALID`。

Chat Worker 校验 effects 后写入后端内的消息、审计记录和事件流。ToolBear Python 后端不执行 bot effects。

#### 9.7.4 Stateful session Bot Gateway 帧

Stateful session 运行时保留 `stateful_command_sessions`；Browser **不**经 HTTP 读写 session 状态（§9.12）。UI 权威为 `pin_kind=session_control` Channel Pin（§3.10）。

| 方向 | 帧 | 说明 |
|------|-----|------|
| Server → Bot | `session.stop_requested` | 用户经 `platform:stop_session` 请求 graceful stop；**不复用** `session.input` |
| Bot → Server | `session.close` | Bot 收尾后关闭 session |
| Bot → Server | `session.effects` | stateful 内 effect batch（channel pin effects） |

**`session.stop_requested`**（Server → Bot）：

```json
{
  "type": "session.stop_requested",
  "api_version": "lilium.chat.bot.v1",
  "session_id": "...",
  "reason": "user_stop",
  "actor_user_id": "...",
  "grace_timeout_ms": 30000
}
```

Bot 应在 `grace_timeout_ms` 内发送 `session.close`；超时后平台 `closeStatefulSession(stop_timeout)` 并 clear pin。

Channel events `stateful_session.started|updated|closed` 为 **可选** domain timeline；Browser 顶栏 **以 `channel.pin.*` 为准**（§10.4）。

### 9.8 Bot 消息 mutation（双 WebSocket）

Bot 对频道消息的创建与修改分两条 WebSocket 路径：

| 路径 | 允许的 mutation |
|---|---|
| 主 Bot Gateway WS（§9.7） | `send_message`、`update_message`、`disable_components`、`start_stream` |
| Stream WS（§9.15） | 单条 streaming message 的 `append`、`finalize` |

提交入口：

- stateless / interaction / passive event 响应：主 Gateway `delivery_result.effects`
- stateful 会话内：主 Gateway `session.effects`
- 流式正文：Stream WS `append` / `finalize`（**不在**主 Gateway 上提交）

**不提供** `POST /api/chat/bot/channels/{channel_id}/messages` 或任何其它 Bot HTTP 消息 mutation 端点。

Bot 消息须满足与 §9.7.3 / §9.13 相同的 effect 校验：目标频道为已 allow 的 `kind=channel` 群聊、scope 含 `chat:messages:write`、components 规则见 §3.8（含 streaming 互斥）。

### 9.9 Passive message_event 订阅

被动 `message_event` 投递**不**提供独立的 Browser 订阅端点：`PATCH /api/chat/channels/{channel_id}/bot-installations/{bot_id}/event-subscriptions/message.created` 及整个 bot-installation 订阅层**不存在**（已移除）。被动订阅能力由 **stateful command 的 `listen_capability`**（§9.3 `execution.mode=stateful`）承载；Bot 声明监听 `message.created` 后，Chat 经 Bot Gateway WS 投递 `kind=message_event`（§9.7.1），`message` 为完整 Browser-visible Message 投影。

规则：

- listener 是 observer/responder only：**无 consume / stop-propagation 语义**。
- 仅支持 `event_type="message.created"`。
- 默认排除 bot 自己 effect 生成的消息（loop prevention）。
- bot 离线时 `message_event` delivery drop/expire，无用户可见错误；不批量重放历史 passive event。

### 9.10 Developer Bots API

Browser JWT 鉴权。Owner-scoped：caller 必须是 `owner_user_id`。

| Method | Path | 说明 |
|---|---|---|
| POST | `/api/chat/bots` | 创建 bot；`Idempotency-Key` 必填 |
| GET | `/api/chat/bots` | 列出 caller 拥有的 bot；`limit`/`cursor` 分页 |
| GET | `/api/chat/bots/{bot_id}` | bot 详情 |
| PATCH | `/api/chat/bots/{bot_id}` | 更新 bot；`Idempotency-Key` 必填 |
| GET | `/api/chat/bots/{bot_id}/tokens` | token 元数据列表（无 plaintext） |
| POST | `/api/chat/bots/{bot_id}/tokens` | 创建 token；响应含一次性 `plaintext` |
| DELETE | `/api/chat/bots/{bot_id}/tokens/{token_id}` | 撤销 token；`Idempotency-Key` 必填 |

**`BotAppSummary` 形状：**

```json
{
  "bot_id": "00000000-0000-7000-8000-000000000601",
  "owner_user_id": "00000000-0000-7000-8000-000000000101",
  "display_name": "My Bot",
  "avatar_url": null,
  "description": null,
  "visibility": "private",
  "status": "active",
  "command_count": 3,
  "created_at": "2026-06-21T05:30:00Z",
  "updated_at": "2026-06-21T05:30:00Z"
}
```

- `visibility`: `private` | `unlisted` | `public` | `official`。设 `official` 需 JWT `admin: true`（否则 `403 ADMIN_ACCESS_REQUIRED`）。
- `status`: `active` | `disabled` | `deleted`。
- **无** `seed-official-bot` 内部路由；official bot 通过 admin API 创建并设 `visibility: "official"`。

**POST `/api/chat/bots` 请求：**

```json
{
  "display_name": "My Bot",
  "avatar_url": null,
  "description": null,
  "visibility": "private",
  "issue_initial_token": true,
  "initial_token_name": "default"
}
```

**POST 响应 (201)：** `{ "bot": BotAppSummary, "initial_token"?: BotTokenCreated }`

**`BotTokenCreated`：** `{ token_id, name, scopes, plaintext, created_at, expires_at }` — `plaintext` 只返回一次。

**PATCH `/api/chat/bots/{bot_id}`：** 至少一个字段；`display_name` / `avatar_url` / `description` / `visibility` / `status`。非 owner → `403 FORBIDDEN`；`visibility: "official"` 需 admin。

### 9.11 Admin Bots API

Browser JWT + `admin: true` 必填；否则 `403 ADMIN_ACCESS_REQUIRED`。

| Method | Path | 说明 |
|---|---|---|
| GET | `/api/chat/admin/bots` | 全局 bot 列表 |
| GET | `/api/chat/admin/bots/{bot_id}` | 任意 bot 详情 |
| PATCH | `/api/chat/admin/bots/{bot_id}` | 更新任意 bot（含 `official` visibility） |
| GET | `/api/chat/admin/bots/{bot_id}/tokens` | token 元数据 |
| DELETE | `/api/chat/admin/bots/{bot_id}/tokens/{token_id}` | 撤销 token |

**GET `/api/chat/admin/bots` 查询参数：** `limit`、`cursor`、`q`（display_name 搜索）、`owner_user_id`、`status`、`visibility`。

**响应：** `{ "items": BotAppSummary[], "next_cursor": string | null }`

Admin PATCH 请求体与 §9.10 owner PATCH 相同，但不校验 ownership。Admin **不能**通过此 API 为他人创建 bot token（无 `POST .../tokens`）；token 创建仍走 owner-scoped §9.10 或由 bot owner 自行操作。

### 9.12 Command directory + stateful session

#### 9.12.1 Global command directory

```http
GET /api/chat/commands/directory?query=help&cursor=&limit=50
Authorization: Bearer <toolbear_browser_jwt>
```

Admin cold-path 全局 command 搜索（非频道 manifest hot path）。查询参数：`query`（必填，prefix/substring 匹配 command name）、`cursor`、`limit`。

响应：`{ "items": CommandDirectoryRow[], "next_cursor": string | null }`。每行至少含 `bot_id`、`bot_command_id`、`command_name`、`help_text`、`bot_display_name`。

#### 9.12.2 Stateful session（Browser 经 Channel Pin）

**不提供** Browser HTTP 端点：

- `GET /api/chat/channels/{channel_id}/stateful-session`（不存在）
- `POST /api/chat/channels/{channel_id}/stateful-session/stop`（不存在）

Browser 恢复与展示 stateful session **只**通过：

1. `bootstrap.channel_pins` / `GET .../channels/{id}` 的 `channel_pins`（§4.1 / §5.2）
2. `channel.pin.*` events + `GET .../events` gap（§6.1b / §10.6）
3. 人工停止：`interaction.submit` + `pin_id` + `platform:stop_session`（§9.6.4）

`stateful_session.*` channel events 可作弱 domain 提示；**不得**驱动独立 Banner session store。

内部保留：`stateful_command_sessions`、`command.invoke` stateful ack（`session_id`）、Bot Gateway `session.*`（§9.7.4）、`STATEFUL_SESSION_BUSY` 等错误码。DM 频道不适用 stateful session pin（`channel_pins=[]`）。

### 9.13 Bot 流式输出（双 WebSocket）

后端实现细节见 `docs/superpowers/specs/2026-06-30-lilium-chat-bot-streaming-and-internal-api-spec.md`。

| ID | Decision | Rationale |
|---|---|---|
| D1 | `/api/chat/bots*` 继续是 Browser Developer/Admin API，不改成 Machine Token owner API | 当前 contract 和实现均以 Browser JWT owner/admin 为锚点 |
| D2 | Machine Token owner-management API 暂不实现 | 需要独立 actor/audit/rate-limit 设计 |
| D3 | 主 Bot Gateway WS 只接受 `start_stream`，不再接受 `append_stream` / `finalize_stream` | 流式正文热路径不应压在 `BotConnection` 内 |
| D4 | 流式 append/finalize 走专用 Stream WS | 一连接一流，按 `{channel_id,message_id}` 路由 |
| D5 | Stream WS append 支持 seq/ack 恢复 | 同连接 gap 用 `received_seq + 1`；重连用 `ack_seq + 1` |
| D6 | 非空 durable partial 在 abandon/expiry 时写入 canonical abandoned message | 用户已见内容不得凭空消失；空 buffer 仅 live cleanup |
| D7 | `message.stream_finalized` 是 canonical final event | 不额外发 `message.created` |
| D8 | Bot read scopes 暂保留，不新增 read endpoint | 需显式 read grant 设计 |
| D9 | Bot attachment upload channel-scoped（§9.17.1 已实现），scope `chat:messages:write` | 上传滥用面大，channel-scoped + pending GC 缓解 |
| D10 | Platform `/permission` 是内部平台命令 | 不属于第三方 Bot runtime API |
| D11 | Rich UI `components` 与 streaming 互斥 | `components` 仅 `send_message` / `update_message`（`stream_state=none`）；stream 路径仅 text/markdown |

| WebSocket | 路由 | DO | 职责 |
|---|---|---|---|
| **主 Bot Gateway WS** | `GET /api/chat/bot/ws` | `BotConnection(bot_id)` | `delivery`；非流式 effect + `start_stream`；delivery 队列 |
| **Stream WS** | `GET /api/chat/bot/channels/{channel_id}/streams/{message_id}/ws` | `BotStreamConnection(channel_id#message_id)` | 单条 stream 的 `append` + `finalize`；seq/ack；live delta fanout |

规则：两条 WS 使用**同一份** Chat Bot Token；**无**独立 stream token；`{channel_id, message_id}` **成对**出现在 Stream WS path；主 Gateway **禁止** `append_stream` / `finalize_stream`；单个 effect batch **不得**同时含 `start_stream` 与 append/finalize。

### 9.14 Streaming effects：`start_stream` 与 `delivery_ack`

主 Gateway 允许的 effect：`send_message`、`update_message`、`disable_components`、`start_stream`（§9.7.3 非流式部分仍有效）。

`delivery_ack` 对成功应用的 effect 携带可选 `effect_results[]`。`start_stream` **必须**返回 `message_id` 与 Stream WS URL：

```json
{
  "type": "delivery_ack",
  "api_version": "lilium.chat.bot.v1",
  "delivery_id": "01J...",
  "status": "applied",
  "effect_results": [
    {
      "client_effect_id": "00000000-0000-7000-8000-000000000910",
      "type": "start_stream",
      "status": "applied",
      "message_id": "00000000-0000-7000-8000-000000000301",
      "stream": {
        "channel_id": "00000000-0000-7000-8000-000000000201",
        "message_id": "00000000-0000-7000-8000-000000000301",
        "ws_url": "/api/chat/bot/channels/00000000-0000-7000-8000-000000000201/streams/00000000-0000-7000-8000-000000000301/ws",
        "expires_at": "2026-06-30T12:00:00Z"
      }
    }
  ]
}
```

`start_stream` effect body：允许 `message.type`、`message.format`（`plain` | `markdown` | `unsafe-markdown`，§3.9.1）、`reply_to_message_id`（或等价 reply 字段）。**禁止**非空 `message.components`（→ `422 BOT_EFFECT_INVALID`）。`message.text` 为空或忽略。`attachment_ids` 当前 **禁止**（与 §9.15.4 finalize 一致）。语义：创建 `message_stream_registry`；**不**插入 canonical `messages`；emit live-only `message.stream_started`；Bot 须在 `expires_at` 前连接 Stream WS。

### 9.15 Stream WebSocket

#### 9.15.1 Route and auth

```http
GET /api/chat/bot/channels/{channel_id}/streams/{message_id}/ws
Authorization: Bearer <bot_token>
Sec-WebSocket-Protocol: lilium.chat.bot.stream.v1
```

Worker：`verifyBotToken` → scopes `chat:runtime:connect` + `chat:messages:write` → `ChatChannel /internal/stream-registry-check` → `BotStreamConnection`（DO name = `` `${channel_id}#${message_id}` ``）。

#### 9.15.2 Frames

`api_version` = `lilium.chat.bot.stream.v1`。

| Direction | Type | Payload |
|---|---|---|
| Bot → Server | `hello` | `{}` |
| Server → Bot | `ready` | `{ channel_id, message_id, expires_at, ack_seq }` |
| Bot → Server | `append` | `{ seq, delta }` |
| Server → Bot | `append_ack` | `{ ack_seq }` |
| Bot → Server | `finalize` | `{ final_seq, attachment_ids? }`（**禁止** `components`；见 §9.15.4） |
| Server → Bot | `finalized_ack` | `{ ok: true, message_id, event_id }` |
| Server → Bot | `stream_error` | `{ code, message, retryable }` |
| Both | `ping` / `pong` | `{}` |

#### 9.15.3 Sequence rules

- `seq` 从 `1` 起，严格递增 1。
- **`ack_seq`** 是 server **已 durable flush** 的最高 seq；Bot 重连后从 **`ack_seq + 1`** 重发。
- **`received_seq`** 是当前活动连接已接受、但可能尚未 durable ack 的最高 seq；gap 与 unacked duplicate 基于 **`received_seq`**，**不是** `ack_seq`。
- `seq <= ack_seq`：durable no-op；`seq == received_seq + 1`：接受；`seq > received_seq + 1`：`BOT_STREAM_SEQUENCE_GAP`。
- unacked duplicate 判重仅在活动 WS attachment 内存 Map；**不**持久化 SQLite；rehydrate 后 `received_seq` 回落到 `ack_seq`。
- `append_ack` 仅在 durable flush 后才 advance `ack_seq`。

#### 9.15.4 Finalize rules

- Streaming 状态下 finalize **只接受** `final_seq == received_seq`。
- `final_seq > received_seq` → `BOT_STREAM_SEQUENCE_GAP`（缺少 delta，**不得** finalize）。
- `final_seq < received_seq` → `BOT_STREAM_CONFLICT`，除非 registry 已为 `status=finalized` 且本次 `finalize_request_hash` 与已存一致（返回 `finalized_response_json`）。
- finalize 前先 flush 已接受 pending text，使 **`ack_seq == received_seq`**。
- Stream `finalize` **禁止**非空 `components`。请求体含非空 `components` → `stream_error` `BOT_EFFECT_INVALID`。Final `messages` 行与 Browser 投影 **`components=[]`**。
- `finalize` 一次 canonical 事务：insert final `messages` + `message.stream_finalized` event + mark registry；**不**额外 emit `message.created`。
- **`finalize_request_hash`** = 稳定 hash（如 SHA-256 hex）over 规范化 JSON `{ final_seq, resolved_text, components: [], attachment_ids }`（`components` **固定为空数组**；缺省字段按 canonical JSON 规则一致化）；**幂等判断用此 hash**。
- registry 持久化 `final_event_id` / `final_text_hash`（诊断，`hash(resolved_text)`）/ `finalize_request_hash` / `finalized_response_json`。
- 已 finalized：相同 `finalize_request_hash` → 返回 stored response；不同 → `BOT_STREAM_CONFLICT`。

#### 9.15.5 Interruption and abandon policy

- Stream WS / 主 Bot Gateway 断连 **不** finalize；bot 可在 `expires_at` 前重连。
- Expiry / abandon 时先 flush 已接受 pending text（若可能），`resolved_partial = stream_state.flushed_text`。
- **`resolved_partial` 为空**（durable `flushed_text` 为空）：
  - 发 live-only `message.stream_abandon_cleanup`（移除 provisional UI）；
  - mark registry `abandoned`/`expired`；clear buffer；
  - **不**写 canonical `messages` / `events`。
- **`resolved_partial` 非空**：
  - `ChatChannel /internal/stream-abandon` 一次 canonical 事务：
    - insert `messages`（`message_id` = registry.message_id，`text = resolved_partial`，`stream_state=abandoned`，`status=failed`，`created_at` = registry.created_at）；
    - insert canonical `message.stream_abandoned` event（payload `{ channel_id, event_id, message }`，同 `projectMessageForBrowser`）；
    - persist registry `abandoned_event_id` / `abandoned_text_hash` / `abandoned_response_json`；mark registry `abandoned`；
    - enqueue canonical ChannelFanout（**不是** live-only stream frame）。
  - **不**额外 emit `message.created`。
  - 在线客户端从 provisional stream UI **收敛**到 abandoned/failed message；离线客户端经 HTTP history/events 可见 partial。
- Abandon 幂等：已 `abandoned` 且相同 `abandoned_text_hash` → 返回 stored `abandoned_response_json`；空 stream repeated cleanup → no-op。
- 已 persisted abandon 后 reject `finalize`（`BOT_STREAM_EXPIRED` / `BOT_STREAM_CONFLICT`）；**不得**覆盖 abandoned message。

### 9.16 Browser stream frames

Streaming 中间态是 live-only，**不得**推进 HTTP recovery cursor。Live-only frames 使用 `frame_type="stream_event"`（`api_version`: `lilium.chat.stream.v1`）。

| Frame type | 存储 | 说明 |
|---|---|---|
| `message.stream_started` | live-only | provisional UI |
| `message.stream_delta` | live-only | batched delta |
| `message.stream_abandon_cleanup` | live-only | 空 stream 移除 provisional UI；不写 history |
| `message.stream_abandoned` | canonical channel event | 非空 partial 中断；HTTP history/events 权威；`stream_state=abandoned`、`status=failed` |
| `message.stream_finalized` | canonical channel event | 正常完成；HTTP history/events 权威 |

`message.stream_started` / `message.stream_delta` / `message.stream_abandon_cleanup` 经 `frame_type="stream_event"` live-only fanout（§9.16 末段）。`message.stream_abandoned` / `message.stream_finalized` 走 canonical channel event 投递（含 HTTP `GET .../events` 与在线 canonical fanout）。

Browser：按 `(channel_id, message_id, stream_seq)` 去重；**不**把 stream frames 存为 channel event cursor；HTTP history/events 为权威。Stream 消息（`stream_state` 为 `streaming` | `final` | `abandoned`）**不**渲染 Rich UI `components`（§3.8）；仅 `stream_state=none` 的非 stream Bot 消息渲染 components。

Live-only fanout 走 `ChannelFanout /internal/deliver-stream-frame`（**不得**复用 canonical `/deliver` 或伪造 `event_id`）。`UserConnection` membership + lease check 后将 `stream_event` 原样发给 Browser。

### 9.17 Bot attachment upload 与 deferred capabilities

#### 9.17.1 Bot channel-scoped image upload

Bot 经 HTTP 上传图片附件，供非 stream effect（`send_message` / `update_message`，`stream_state=none`）引用 `attachment_ids`（`type: "image"`）。Stream 路径（`start_stream`、Stream WS `finalize`）仍 **禁止** `attachment_ids`（§9.14 / §9.15.4）。

```http
POST /api/chat/bot/channels/{channel_id}/uploads/images/presign
Authorization: Bearer <bot_token>
Idempotency-Key: <uuid>
Content-Type: application/json

{
  "filename": "photo.png",
  "mime_type": "image/png",
  "size_bytes": 12345,
  "width": 512,
  "height": 512,
  "blurhash": "LKO2?U%2Tw=w]~RBVZRi};RPxuwH"
}
```

响应：`{ attachment_id, upload_url, upload_headers, expires_at }`（presigned PUT 语义同 §8.1）。

```http
POST /api/chat/bot/channels/{channel_id}/uploads/images/{attachment_id}/finalize
Authorization: Bearer <bot_token>
Content-Type: application/json

{ "etag": "\"abc123\"" }
```

响应：`{ attachment: FinalizedAttachmentProjection }`（同 §8.2）。

规则：

- Required scope：`chat:messages:write`（`getBotIdentity` gate，同 Bot Gateway write path）。
- Bot 须 **已安装** 于 `{channel_id}`（active `bot_installations` row）。
- Presign 写入 `attachments`：`status=pending`，`owner_bot_id=bot_id`，`channel_id`，`kind=image`；`owner_user_id` 为空；`expires_at = now + 24h`（同 user upload idempotency TTL）。未 finalize 的 pending 行由 ChatChannel alarm GC（删除 S3 对象 + SQLite 行）。
- Finalize：HEAD S3、mime whitelist、size cap（同 user upload §8.2）。
- **归属：** attachment 仅可在 presign 同一 `channel_id` 的非 stream effect 中引用；跨 channel 或 user-owned attachment → `BOT_EFFECT_INVALID`。
- 消息 mutation 仍只经 WS effects；HTTP 上传仅产生可引用的 `attachment_id`。

#### 9.17.2 Deferred capabilities（explicit non-goals）

| Capability | Status | Rationale |
|---|---|---|
| Machine Token on `/api/chat/bots*` | Deferred | Owner API stays Browser JWT (§9.10/§9.11) |
| Bot read APIs (`chat:*:read` scopes) | Deferred | No product consumer yet |
| HTTP callback transport | **Will not implement** | WS delivery is the only bot transport |
| Signed attachment URL / read proxy | **Will not implement** | Public-read SeaweedFS URLs accepted risk (§1 附件 risk acceptance) |
| Admin audit API (deleted/recalled 原文) | Deferred | Ops uses PG archive / lilium-ng message store (`ChatChannel` archive outbox → PG) |
| Passive `message_event` delivery | Deferred | 无独立订阅 API；仅 stateful command `listen_capability` 场景使用（§9.9） |
| `last_message_preview` text | Deferred | §5.6 already documents `null` |

### 9.18 Platform `/permission` command

内部 platform command（§9.2 platform bot identity）；owner/admin 在非 DM manifest 可见；内联 `command.invoke`，**不**经 Bot Gateway delivery。`/permission` 列表；`/permission <name> on|off` 写 binding rows；official command `on` → `OFFICIAL_COMMAND_AUTO_ALLOWED`。

列表与变更确认消息使用 `format=unsafe-markdown`（§3.9）：标题/分组用标准 Markdown；命令名使用 slash command chip 虚拟链接 `` [`/name`](/command:name) ``。

## 10. 实时与事件回放

### 10.1 WebSocket 连接

```text
wss://chat.kuma.homes/api/chat/ws
```

前端通过 WebSocket subprotocol 携带 ToolBear browser JWT：

```js
new WebSocket("wss://chat.kuma.homes/api/chat/ws", [
  "lilium.chat.v2",
  "bearer.<toolbear_browser_jwt>"
])
```

Worker 只接受 `lilium.chat.v2` + `bearer.<jwt>`（`lilium.chat.v1` 已废弃）。JWT 与 Origin 规则同 §2.1。

**Connect 语义：** WebSocket 建立用户级 live session。鉴权成功后 server `acceptWebSocket` 并创建 `UserConnection` live session。

Connect **必须不**：

- replay 历史 channel events
- 使用 Browser 提供的 per-channel cursors
- 执行 gap recovery
- 隐式订阅全部频道或写 `ChannelFanout`

历史数据、重连恢复、gap recovery 由 **HTTP read APIs** 处理（§10.6）。Query `cursors` 已从 contract 移除；旧客户端传入则 **MAY ignore**，**MUST NOT** 用于 `UserConnection` replay。

**Live fanout 启动：** WS `open` 后客户端自动发 `session.live_start`（§5.11）。Committed 后接收全部 active 成员频道的新 event（best-effort，§10.5）。

推荐启动顺序：

```text
1. Open WebSocket（subprotocol `lilium.chat.v2`）
2. Send session.live_start
3. After ack → HTTP bootstrap / refresh channel list
4. If active channel → HTTP channel sync (§6.1b or §6.1)
```

### 10.2 CommandAck

Worker 收到 command frame 后做协议校验并执行业务事务。事务提交后返回 committed_ack（ack 携带 command-specific canonical mutation payload）：

```json
{
  "frame_type": "command_ack",
  "command": "message.send",
  "command_id": "00000000-0000-7000-8000-000000000411",
  "status": "committed",
  "payload": {}
}
```

通用规则：

- `command_id` 从 command frame 回显。
- `status="committed"` 表示目标 DO 事务已提交。
- `payload` 包含该 command 的 canonical result（command-specific 形状）。
- 重复幂等重试返回**完全相同**的 committed ack payload。
- `payload` 必须包含客户端 reconcile 所需的服务端生成 ID。

`payload` 形状按 command 类型：

- `message.send` / `message.edit` / `message.recall` / `message.delete` → `{ channel_id, event_id, message }`，`message` 为完整 Browser-visible Message 投影（见 §6.2/§6.3/§6.4/§6.5、§3.4）。
- `channel.mark_read` → `{ channel_id, last_read_event_id, unread_count }`（无 `event_id`，见 §5.5）。
- `session.live_start` → `{ session_id, subscribed_channel_count, lease_expires_at }`（§5.11）。
- `session.heartbeat` → `{ session_id, lease_expires_at }`（§5.12）。
- `command.invoke` / `interaction.submit`（timeline）→ 含 `invocation_id` / `interaction_id` + `event_id` 等 reconcile 所需 ID。
- `interaction.submit`（`platform:` 平台短路）→ **`PlatformPinInteractionAck`**：`{ channel_id, event_id, pin_id, session_id, custom_id }`，**不含** `interaction_id`（§9.6.4）。
- `channel.pin_message` → `{ channel_id, event_id, pin }`（§6.7.1）。

`message.*` 的 ack `payload.message` 与对应 event frame 的 `payload.message` **同形**（同一 `projectMessageForBrowser` builder 产物）。前端 reducer 把 ack 与 event 视为按 `message_id` 的收敛 upsert：先收到 ack 用 `payload.message` 替换本地 pending；后收到 event frame 再 upsert 同一 `message_id`，不产生重复行；event frame 是最终 timeline 收敛来源，ack 是发起 command 的即时提交结果。

committed_ack 携带提交结果，前端可立即绑定本地 pending。event frame 仍是最终 timeline 状态。

协议校验失败返回 `command_error`：

```json
{
  "frame_type": "command_error",
  "command_id": "00000000-0000-7000-8000-000000000411",
  "error": {
    "code": "INVALID_MESSAGE",
    "message": "message text is empty",
    "retryable": false
  }
}
```

### 10.3 事件回放

```http
GET /api/chat/events?channel_id=00000000-0000-7000-8000-000000000201&after_event_id=01J...
```

或 per-channel cursor map 取用户所有频道（UserDirectory 拿列表 → 并行查各频道 → 归并）：

```http
GET /api/chat/events?cursors=<base64url(JSON {channel_id: after_event_id})>
```

响应：

```json
{
  "items": [],
  "next_cursor": null,
  "last_event_id_per_channel": {
    "00000000-0000-7000-8000-000000000201": "01J..."
  }
}
```

`last_event_id_per_channel` 是 per-channel 的最后事件 cursor（无全局单值 cursor）。

事件回放返回的是 Browser 可见事件投影：

- `message.created` replay 只返回当前仍可见的消息；已被删除/撤回的不会以 `message.created` 返回。
- **所有 content-bearing event replay（message.created / message.updated / message.stream_* / interaction.completed / command.completed）都通过当前 message status 过滤**。deleted/recalled 的消息，其 created/updated/stream_* event 不重放；deleted/recalled event 只返回 tombstone。
- `message.deleted` 和 `message.recalled` replay 只返回 `message_id`、`channel_id`、`status`、操作时间和操作者摘要，不返回原始 `text`、`attachments`、`components`、`mentions`。
- event payload 不持久化 UserSummary profile，只存 actor 引用；UserSummary 在输出时实时 resolve。
- **`command.invoked` / `interaction.created` replay**：storage 只存 `actor_user_id`（及 `command_name`/`invoked_name` 或 `message_id`+`component_id`）；HTTP replay 与 live broadcast 回填 `actor` UserSummary 与 `command_name` / `component_label`（见 §9.6.2）。
- 前端收到 `message.deleted` 或 `message.recalled` 后，从本地时间线移除该消息项。

### 10.4 EventEnvelope

```json
{
  "frame_type": "event",
  "api_version": "lilium.chat.v1",
  "event_id": "01J...",
  "type": "message.created",
  "channel_id": "00000000-0000-7000-8000-000000000201",
  "occurred_at": "2026-06-21T05:30:00Z",
  "payload": {}
}
```

`message.*` 事件 payload 形状：`message.created` / `message.updated` / `message.recalled` / `message.deleted` 的 `payload` 为 `{ channel_id, event_id, message }`，其中 `message` 为**完整 Browser-visible Message 投影**（sender UserSummary、type、format、status、stream_state、text、reply_to、reply_snapshot、attachments、components、mentions、created/updated/edited/deleted/recalled 时间戳），与对应 committed ack 的 `payload.message` **同形**——同一 `projectMessageForBrowser` builder 产物（完整 `message.created` event 示例见 §6.2）。`message.recalled` / `message.deleted` 的 event payload 必须用安全投影：`text=null`、`attachments=[]`、`components=[]`、`mentions=[]`，不泄露原文/附件/components/mentions。`events.payload_json`（DO storage）不持久化 UserSummary，只存 sender/actor 引用；`sender` 的 `display_name`/`avatar_url` 在输出时（live broadcast + replay）由 `resolveUserSummaries` 实时回填。

`interaction.completed` 的 `payload.message` 与 `message.*` event **同形**（content-bearing，replay 按当前 message status 过滤，§10.3）。`command.invoked` / `interaction.created` 的 wire payload 含 `actor` 等展示字段，storage 规则见 §9.6.2。

事件类型：

- `channel.created`
- `channel.updated`
- `channel.archived`
- `channel.dissolved`
- `member.joined`
- `member.left`
- `member.role_updated`
- `system.notice`
- `message.created`
- `message.updated`
- `message.deleted`
- `message.recalled`
- `message.stream_finalized`（canonical channel event；streamed bot message **不**额外发 `message.created`，见 §9.15）
- `message.stream_abandoned`（canonical channel event；bot stream 非空 partial 中断；**不**额外发 `message.created`，见 §9.15.5）
- `command.invoked`
- `command.completed`
- `command.failed`
- `interaction.created`
- `interaction.completed`
- `interaction.failed`
- `channel.pin.set`
- `channel.pin.updated`
- `channel.pin.cleared`
- `stateful_session.started`（可选 domain；UI 以 pin 为准）
- `stateful_session.updated`
- `stateful_session.closed`

`channel.pin.*` payload：

| type | payload |
|------|---------|
| `channel.pin.set` | `{ pin: ChannelPin }` |
| `channel.pin.updated` | `{ pin: ChannelPin }` |
| `channel.pin.cleared` | `{ pin_id, channel_id, pin_kind?, session_id?, source_message_id? }` |

写入 `ChatChannel.events`；fanout + `GET .../events` replay；**不**进入 `GET .../messages`。

> **Live-only stream frames**：`message.stream_started`、`message.stream_delta`、`message.stream_abandon_cleanup` **不是** channel timeline event，不写入 `ChatChannel.events`，不进入 HTTP `GET .../events` 恢复。它们经 Browser WS 以 `frame_type="stream_event"` 投递（§9.16）。`message.stream_abandoned`（非空 partial）与 `message.stream_finalized` 是 canonical channel events；离线/刷新客户端经 HTTP history/events 可见。

> `read_state_updated`（见 §5.5）是 user-local WS frame，**不是** channel timeline event，不写入 `ChatChannel.events`，不列入上方 channel event 类型表。

`system.notice` 是服务端生成的弱提示行事件，不替代 domain event。服务端在同一 ChatChannel 事务中为 timeline-visible 管理动作追加 `system.notice`：成员加入/离开/角色变更、频道更新/归档/解散、管理员删除他人消息。前端按 `notice_kind` 渲染文案，服务端不下发展示文案。

`system.notice` payload：

```json
{
  "notice_kind": "channel.dissolved",
  "actor": {
    "user_id": "00000000-0000-7000-8000-000000000101",
    "display_name": "alice",
    "avatar_url": null
  },
  "target_user": null,
  "message_id": null,
  "channel_changes": null
}
```

字段规则：

- `notice_kind`: `member.joined` | `member.left` | `member.role_updated` | `channel.updated` | `channel.archived` | `channel.dissolved` | `message.deleted`
- `actor`: 触发动作的用户；system actor 时为 `null`。
- `target_user`: 成员相关 notice 的目标用户，其余为 `null`。
- `message_id`: `message.deleted` notice 的目标消息，其余为 `null`。
- `channel_changes`: `channel.updated` 的字段级变更摘要，其余为 `null`。形状为 `{ "<field>": { "before": <old>, "after": <new> } }`，`field` 仅允许 `title`、`topic`、`avatar_url`、`visibility`。

> **Storage vs wire projection**：以上 `system.notice` payload 是 **Browser projection**。`events.payload_json`（DO storage）**不持久化 UserSummary**，只存 `actor_user_id` / `target_user_id` / `notice_kind` / `message_id` / `channel_changes` 等引用与结构字段。`actor.display_name` / `actor.avatar_url` / `target_user` 的 UserSummary 在输出时（live broadcast + replay）由 `resolveUserSummaries` 实时回填，与 `message.created` 的 sender 解析规则一致（§10.3）。实现时切勿把 display_name/avatar_url 落进 DO storage。

前端规则：

- 按 `event_id` 在**对应频道内**去重。
- 只接受大于本地该频道的 `last_event_id` 的事件。
- 事件落入本地状态后再更新该频道的 `last_event_id`。
- 收到 gap 错误后重新调用 `GET /api/chat/bootstrap?channel_id=...` 或 `GET /api/chat/channels/{channel_id}/events`（§6.1b）。

### 10.5 WS live event delivery 语义

Browser WS live events 为 **best-effort**：

- Server **SHOULD** 向 active live session 投递各 active 成员频道的新 event。
- Server **不保证** WebSocket exactly-once delivery。
- Server **不保证** 恢复以下期间错过的事件：disconnect、reconnect、tab suspension、deploy、DO restart/hibernation、网络失败、backpressure、lease expiry。

Browser **必须** 按 `(channel_id, event_id)` dedupe。Browser **必须** 通过 HTTP bootstrap 与 channel history/events API 恢复权威状态（§10.6）。

每个 live event frame **必须** 含 `frame_type`、`type`（event 类型）、`channel_id`、`event_id`、`payload`。Live event **SHOULD** 与 HTTP history / committed mutation ack 使用同一 Browser 投影 builder（§10.4）。`api_version` 为 `lilium.chat.v1`（event frame 字段；WS subprotocol 为 `lilium.chat.v2`，见 §10.1）。

成员关系变化后，server 会在 `UserDirectory /my-channels` projection 可见后按 `affected_user_id` 主动 resync 该用户所有 live sessions。Browser 可能收到 user-scoped hint：

```json
{
  "frame_type": "user_event",
  "event": "my_channels_changed",
  "reason": "member_added",
  "changed_channel_id": "01..."
}
```

该 frame 不是 channel timeline event，不包含 `event_id`，不写入历史，不经 `ChannelFanout`。Browser 可据此刷新 channel list/bootstrap；漏收该 hint 不影响正确性，HTTP 仍是权威。

客户端应用规则：

- `event.channel_id === activeChannelId` → 写入 active timeline。
- 否则 → 只更新 channel list / unread，不 append 到 active timeline。
- `user_event my_channels_changed` → 刷新用户频道列表/bootstrap，不写入任何频道 timeline。

### 10.6 HTTP 权威恢复

WebSocket **不得**作为历史真相或 gap repair 来源。权威恢复触发见 §6.1b。实现 **必须** 提供足以在本地 cursor 之后恢复 canonical message/timeline 状态的 HTTP API（`GET .../events` 或等价的 `GET .../messages`）。

**Channel Pin 恢复（normative）**：

```
snapshot ← bootstrap.channel_pins + event_state.per_channel[id]
for each event where event_id > cursor:
  apply channel.pin.* / message.* / …
  cursor ← event_id
```

- Pin 冷启动用 **`channel_pins` 快照**（§4.1 不变量），不扫 messages。
- Gap **必须**用 `GET .../events?after_event_id=cursor`（覆盖 `channel.pin.*`）；**禁止**用 `getMessages(after)` 修 pin gap。
- Stop 不乐观 remove pin；等 `channel.pin.cleared`。

全局多频道恢复仍可用 `GET /api/chat/events?cursors=...`（§10.3）。单频道 active timeline 同步优先 `GET /api/chat/channels/{channel_id}/events`（§6.1b）。

## 11. 错误码

HTTP error envelope 和 WebSocket `command_error.error` 使用同一套 `code`。

| HTTP | code | 含义 |
|---:|---|---|
| 401 | UNAUTHORIZED | 未登录或 token 失效 |
| 401 | MACHINE_TOKEN_NOT_ALLOWED | machine token 不允许访问 Browser API |
| 403 | SESSION_NOT_ALLOWED | delegated / managed session 不允许进入聊天 |
| 403 | FORBIDDEN | 当前用户无权执行该 action |
| 403 | ADMIN_ACCESS_REQUIRED | JWT 无 `admin: true` 却访问 admin API 或设置 `visibility: official` |
| 404 | CHANNEL_NOT_FOUND | 频道不存在或不可见 |
| 404 | MESSAGE_NOT_FOUND | 消息不存在或不可见 |
| 404 | MEMBER_NOT_FOUND | 用户不是该频道成员（从未加入） |
| 404 | INVITE_NOT_FOUND | 邀请不存在、不可见、已撤销或已过期 |
| 409 | CHANNEL_ARCHIVED | 频道已归档，不允许写入 |
| 409 | CHANNEL_DISSOLVED | 频道已解散，不允许写入或成员变更 |
| 409 | SESSION_NOT_LIVE | `session.heartbeat` 时 session 尚未 `session.live_start` |
| 409 | MESSAGE_NOT_EDITABLE | 消息类型或状态不允许编辑 |
| 409 | IDEMPOTENCY_CONFLICT | 同一 operation id（HTTP `Idempotency-Key` / WS `command_id`）请求体不一致 |
| 409 | ROUTE_INDEX_PENDING | invite-code 路由索引 lag 窗口，重试可路由到（仅 invite-code 路由使用；消息操作永不返回） |
| 413 | ATTACHMENT_TOO_LARGE | 附件超出大小限制 |
| 415 | UNSUPPORTED_ATTACHMENT_TYPE | 附件 MIME type 不允许 |
| 422 | INVALID_MESSAGE | 消息请求不合法；或 `interaction.submit` 同时有/无 `message_id` 与 `pin_id` |
| 404 | STICKER_NOT_FOUND | sticker 不存在或不属于当前用户 |
| 409 | STICKER_LIBRARY_LIMIT_EXCEEDED | 当前用户的表情库已达服务端上限 |
| 422 | INVALID_STICKER_SOURCE | 源 channel/attachment 不可作为 image/sticker 保存 |
| 409 | COMMAND_NAME_CONFLICT | 同一频道内 slash command 名称冲突 |
| 409 | OFFICIAL_COMMAND_AUTO_ALLOWED | 对 official bot command 发 `status: "allowed"` binding；official 命令已全局 auto-allow，只能 `blocked` |
| 404 | COMMAND_NOT_FOUND | command binding 不存在/disabled 或 `invoked_name` 不命中该频道 |
| 422 | INVALID_COMMAND_OPTIONS | command 参数不合法 |
| 404 | COMPONENT_NOT_FOUND | 组件不存在或不可见 |
| 409 | COMPONENT_DISABLED | 组件已禁用 |
| 409 | COMPONENT_ALREADY_USED | `interaction_policy=exclusive` 且该 component 已被他人成功提交 |
| 409 | INTERACTION_ALREADY_SUBMITTED | `interaction_policy=per_user_once` 且该用户已提交过 |
| 403 | INTERACTION_FORBIDDEN_TARGET | `interaction_policy=targeted` 且提交者不是 `target_user_id` |
| 422 | INVALID_INTERACTION_VALUE | interaction value 不合法 |
| 404 | BOT_NOT_FOUND | bot 不存在或非 active（install/bot-get 时） |
| 409 | BOT_COMMAND_DISABLED | command.invoke 时目标 command 在当前 BotRegistry catalog 已 disabled/deleted |
| 503 | BOT_OFFLINE | command.invoke/interaction.submit precheck 时 bot 未连接 Bot Gateway WS，可重试 |
| 422 | BOT_EFFECT_INVALID | bot `delivery_result` 返回的 effect 校验失败（ownership/stream 不变量/components 非法；含 Bot 使用 `platform:` custom_id） |
| 409 | BOT_EFFECT_CONFLICT | 同一 `(channel_id, bot_id, client_effect_id)` 配不同 effect body |
| 404 / WS | BOT_STREAM_NOT_FOUND | Stream registry 不存在或不属于该 bot |
| 409 / WS | BOT_STREAM_CONFLICT | 同一 pending stream seq 复用但 delta 不同 |
| 409 / WS | BOT_STREAM_SEQUENCE_GAP | append seq 跳过 `received_seq + 1`（同连接内），可重试 |
| 410 / WS | BOT_STREAM_EXPIRED | stream 在 finalize 前过期 |
| 403 / WS | BOT_SCOPE_DENIED | bot token 缺少所需 scope |
| 403 / WS | COMMAND_PERMISSION_DENIED | 用户无权执行 platform `/permission` |
| 429 | RATE_LIMITED | 限流命中，可重试 |
| 503 | BOT_CALLBACK_UNAVAILABLE | future HTTP callback transport 预留；当前唯一 runtime transport 为 Bot Gateway WS，此码不返回 |
| 503 | CHAT_WORKER_UNAVAILABLE | worker 暂不可用，可重试 |
| 409 | EVENT_GAP | 事件断层，需要重新拉取 bootstrap |
| 404 | PIN_NOT_FOUND | `pin_id` / pin update / clear 目标不存在 |
| 403 | PIN_FORBIDDEN | Bot 操作非自有 pin；非 owner/admin `channel.pin_message` |
| 409 | SESSION_STOP_IN_PROGRESS | 重复 `platform:stop_session`（session 已 `closing`） |
| 422 | PIN_SOURCE_INVALID | `pinned_message` 源消息不可 pin（非 text / streaming / deleted 等） |

`CHAT_WORKER_UNAVAILABLE` 的 `retryable` 必须为 `true`。`ROUTE_INDEX_PENDING`、`RATE_LIMITED` 的 `retryable` 必须为 `true`。`RATE_LIMITED` 响应带 `Retry-After` 头。

`ROUTE_INDEX_PENDING` must never be returned for message operations because Browser message operations are always channel-scoped and routed directly to `ChatChannel DO`。`ROUTE_INDEX_PENDING` 只用于 invite-code 路由（`POST /api/chat/invites/{invite_code}/accept`），因 invite URL 天然不含 `channel_id`。

### 11.1 不进入 Browser API 的设置项

以下前端设置项不进入 Browser API，不要求 Worker / DO schema：

- 群聊标签：disabled 只读占位，无读取端点，无 mutation。
- 免打扰：browser local-only UI state，不写入 chat API，不跨设备同步。

## 12. 实现不变量


以下不变量是实现的 normative 约束，与正文各节 wire shape 配套。

### 12.1 WS committed_ack

与 §2.5 / §5.5 / §6.2–§6.5 / §10.2 / §10.4 同步生效：

1. 每个 committed WS mutation ack 返回 command-specific 的 canonical result payload。
2. `message.*` committed ack payload 包含 `{ channel_id, event_id, message }`。
3. `payload.message` 是 mutation 后的 Browser-visible Message 投影。
4. `message.*` event payload 使用与 ack 相同的 Browser-visible Message 投影形状。
5. deleted/recalled 的 message 投影不得暴露原始 text、attachments、components、mentions。
6. `channel.mark_read` ack payload 包含 read-state，不包含 `event_id`。
7. 幂等缓存存完整 committed ack payload（不只 ID）。
8. ack 与 event reducer 必须是按 `message_id` / `event_id` 的幂等 upsert。

### 12.2 Bot Gateway WS RPC

与 §9.7 / §9.9 / §11 同步生效：

1. Bot runtime delivery 唯一 transport 为 Bot Gateway WebSocket RPC（`/api/chat/bot/ws`）；HTTP callback 不实现（future transport）。
2. Bot WS 与 Browser WS 物理分离；Bot 不复用 Browser WS。
3. `BotRegistry` 为 singleton DO；token 验证单点 `SELECT ... WHERE token_hash=?`。
4. `BotConnection` 持有 bot WS + delivery 队列；ChatChannel 经 `bot_delivery_outbox` 异步 fan-out。
5. delivery at-least-once；effects 按 `(channel_id, bot_id, client_effect_id)` 幂等。
6. ChatChannel 是 invocation / interaction / effect 应用 source-of-truth。
7. outbox status 与 invocation/interaction lifecycle status 分开。
8. bot offline policy 见 §9.7.2。
9. passive `message_event` observer/responder only。
10. Bot catalog sync 是 outbound HTTP；Bot 消息 mutation 只走 Gateway WS effects。

### 12.3 Live Fanout

与 §5.11 / §5.12 / §10.1 / §10.5 / §10.6 同步生效：

1. WebSocket live delivery 是 best-effort，永远不是历史真相来源。
2. HTTP read APIs 是 bootstrap、history、reconnect、resume、gap recovery 的权威来源。
3. Browser live session 在 `session.live_start` 后自动接收全部 **当前 active** 成员频道新 events。
4. `UserConnection` 不得做 replay 或 cursor recovery。
5. `UserConnection` 不得使用 `ctx.waitUntil` 做有副作用的连接初始化。
6. `ChannelFanout` 存 `fanout_leases`（临时 cache），不是权威在线状态。
7. Close/error 清理是 best-effort；lease TTL + prune + stale cleanup 提供收敛。
8. WebSocket attachment 不是 subscribed channels 权威来源。
9. 前端按 `(channel_id, event_id)` dedupe；恢复走 HTTP。
10. **不暴露** `channel.subscribe` / `channel.unsubscribe`。
11. `channel.mark_read` 的 `last_read_event_id` 不是 WS delivery cursor。
12. 不存在 connect replay、`?cursors=` on WS、旧 register/unregister-online 写路径。
13. `/deliver` membership re-check 规则见 §10.5。
14. `session.heartbeat` 不得复活 stale lease。
15. `live_channel_leases.membership_version` 在 live_start / deliver re-check / heartbeat 时写回。
16. Membership mutation live resync 以 `affected_user_id` 为 key。
17. Heartbeat 是 fallback convergence，不是主路径。
18. 关闭后的 lease 仅 active membership 恢复时可 reopen，且须新 `lease_id`。
19. `UserDirectory /my-channels` reload 失败不得解释为空 membership set。

### 12.4 Bot streaming

与 §9.13–§9.16 及 backend spec 同步生效：

1. 主 Bot Gateway WS 与 Stream WS 物理分离；主 Gateway **不得**提交 `append_stream` / `finalize_stream`。
2. 流式进行中 **不**写入 canonical `messages` / `events`；**finalize** 写 `message.stream_finalized`；**abandon 且非空 partial** 写 `message.stream_abandoned`。
3. Streamed bot message **不**额外 emit `message.created`（含 finalized 与 abandoned partial）。
4. `message.stream_started` / `message.stream_delta` / `message.stream_abandon_cleanup` 是 live-only `stream_event` frames；`message.stream_abandoned`（非空 partial）与 `message.stream_finalized` **进入** HTTP `GET .../events`。
5. `BotStreamConnection` DO name = `` `${channel_id}#${message_id}` ``；append hot path **不**写 ChatChannel SQLite per-delta。
6. gap 检测用运行时 `received_seq + 1`，**不是** `ack_seq + 1`；`append_ack.ack_seq` 不得 advance 超过 durable `flushed_text`。
7. unacked duplicate 判重仅在活动 WS attachment 内存；rehydrate 后 `received_seq` 回落到 `ack_seq`。
8. Stream expiry/abandon：非空 durable `flushed_text` → canonical abandoned message（`stream_state=abandoned`、`status=failed`）；空 buffer → live-only `message.stream_abandon_cleanup`，无 history row。
9. Effect 幂等键 `(channel_id, bot_id, client_effect_id)` 不变；`start_stream` 重放返回相同 `{ message_id, ws_url, expires_at }`。
10. Append 幂等：`seq <= ack_seq` durable no-op；unacked duplicate 同 hash no-op / 异 hash `BOT_STREAM_CONFLICT`；seq gap → `BOT_STREAM_SEQUENCE_GAP`。
11. Finalize：`final_seq == received_seq`（`>` → `BOT_STREAM_SEQUENCE_GAP`，`<` → `BOT_STREAM_CONFLICT` 除非已 finalized 且 hash 命中）；finalize 前 `ack_seq == received_seq`；registry 持久化 `final_event_id` / `final_text_hash`（诊断）/ `finalize_request_hash` / `finalized_response_json`；幂等按 `finalize_request_hash`，不同 hash → `BOT_STREAM_CONFLICT`。
12. Abandon：`/internal/stream-abandon`；registry 持久化 `abandoned_event_id` / `abandoned_text_hash` / `abandoned_response_json`；幂等按 `abandoned_text_hash`；finalize 后 abandoned 不得覆盖。
13. Live stream fanout 走 `ChannelFanout /internal/deliver-stream-frame`；**不得**复用 canonical `/deliver` 传递 live-only frames。
14. Machine Token owner API、Bot read API **不**实现；Bot channel-scoped attachment upload **已实现**（§9.17.1）。
15. Rich UI `MessageComponent` **仅**非 stream Bot 消息（`stream_state=none`，`send_message` / `update_message`）。`start_stream`、Stream WS `finalize`、stream 消息投影 **禁止**非空 `components`；Browser 仅 `stream_state=none` 渲染 components（§3.8）。

