# Conformance harness (spec §7 / issue #1)

把 `docs/api-contract.md`（v2.31）变成可执行黑盒测试：同一 scenario 脚本分别打
**旧 Worker**（本地 `wrangler dev`，干净 miniflare state）和**新 Elixir**（干净 PG
`chat_v2.*`），捕获全部 HTTP/WS 响应；diff 前先把易变字段归一化为占位符再比对。
这是 cutover 前一切 parity 验收的 **go/no-go 闸门**。

## 机制（spec §7.1–§7.3）

```
scenario script (scenarios/*.ts, deterministic inputs)
        │  same script, both targets start from EMPTY state → 脚本即 fixture
        ▼
runner (src/runner.ts) ── HTTP + WS capture, in order, per step
        ▼
normalize (src/normalize.ts) ── 易变字段 → 占位符（非白名单忽略）
        ▼
diff (src/diff.ts) ── structural diff of the two normalized captures
        ▼
report (reports/*.txt|json) + exit code: 0 = parity, 1 = diff/observation fail, 2 = harness error
```

**归一化规则**（替换，不是忽略）：

| 易变字段 | 占位符 |
|---|---|
| 服务端生成 UUID（message/event/channel/session id…） | `{{UUID}}` |
| ISO-8601 / HTTP-date 时间戳 | `{{TS}}` |
| `req_<uuidv7>` request id（header + body） | `req_{{UUID}}` |
| `Authorization: Bearer <jwt>`（仅 header 值） | `{{JWT}}` |

**客户端生成的 id 不归一化**：scenario 里写死的 `command_id`、`Idempotency-Key`、
actor user id（插值前的静态 UUID 字面量 + actor 定义，见
`collectKnownClientIds`）。它们是确定性输入，两边必须原样回显——回显不一致就是
真 diff。服务端 mint 的 id 只经 `${var}` 插值进入请求，因此必然被归一化。

**capture 边界**：每个 WS step 以谓词关闭窗口，窗口内所有帧按到达顺序入 capture。
`ws.command` 可带 `alsoUntil`（例如 message.send 的 committed ack **和** 1 条
`message.created` fanout 同窗）——ack/event 谁先到都落在同一步，避免时序把帧拆到
不同 step 造成误报。`retryUntil`（等异步投影）只记录最后一次响应；`wait` 是同步
屏障，不记录。

## 命令

```bash
cd conformance
npm install

# 1) 快速 CI 证明（无外部依赖）：两个独立 mock 实例跑同一 scenario，
#    随机易变值 → 归一化后必须 diff 为空（AC-2「diff 不误报」的机制证明）
npm run test                  # vitest，含 self-test 断言
npm run conformance -- self-test

# 2) 真·闸门：旧 Worker vs 新 Elixir（顺序执行，共享 dev PG）
#    前置：podman compose up -d postgres && scripts/dev.sh server
npm run conformance -- run --targets worker,elixir

# 3) 机制证明：旧 Worker 自比（两次全新 miniflare state），归一化 diff 必须为空
npm run conformance -- run --targets worker,worker
```

环境变量：`CONFORMANCE_JWT_SECRET`（默认用旧 repo 测试 secret）、
`CONFORMANCE_DB_URL`（默认 `postgres://chat:chat@127.0.0.1:5432/lilium_chat_dev`）、
`CONFORMANCE_OLD_REPO`（默认 `../lilium-chat`）。

## 目标（targets）

| target | state reset | 说明 |
|---|---|---|
| `worker[:port]` | 全新 `--persist-to` 目录（干净 miniflare state） | spawn 旧 repo 的 `wrangler dev --config wrangler.conformance.jsonc`；旧 repo **零改动**（config/.dev.vars 在本包内，`main` 指向旧 entrypoint；Hyperdrive → 共享 dev PG 供 profile 解析） |
| `elixir[:url]` | `DROP SCHEMA chat_v2 CASCADE` + `mix ecto.migrate`（one-shot 容器）+ seed `public.users` | app 进程由 dev flow 拥有（`scripts/dev.sh server`），harness 只管 state reset + readiness |
| `mock` | 内存清空 | in-process contract mock，易变值随机化；CI self-test 用 |

## Scenario：`bootstrap-send-fanout`（Phase 0 代表子集，spec §7.4）

```
GET /bootstrap（空态, read probe）
POST /channels（Idempotency-Key, capture channelId）
GET /channels（retryUntil 等投影落定 — 旧 Worker outbox+alarm 异步）
WS connect（subprotocol lilium.chat.v2 + bearer.<jwt>, Origin 白名单）
WS session.live_start → committed ack
wait 1s（fanout lease 注册宽限 — 两侧实现均为带外注册）
WS message.send → committed ack（完整 message 投影）
WS event message.created（**1 条 fanout**，best-effort §10.5）
GET /bootstrap?channel_id=…（post-state, read probe）
```

## 读路径观测断言（spec §7.5 / D15 / A12）

标记 `readProbe` 的 step（两个 bootstrap GET）在 Elixir target 上自动包一层 PG 级观测：

- **无隐藏写**：对 `chat_v2.*` + `public.users` 全部表临时挂 AFTER ROW trigger →
  `conformance.write_audit`；读请求后审计表必须为空。
- **查询数有界**：`pg_stat_statements_reset()` 后执行读请求，统计语句数 ≤
  `maxQueries`（当前 50，宽松起步；#3 落 telemetry 后可收紧）。

观测结果写入 report JSON + 终端摘要，**不参与跨 target wire diff**（它是单侧验收
数据）。旧 Worker 的 DO state 在 miniflare 内、其 PG 流量仅 profile 解析，故不挂 probe。

## 当前 go/no-go 语义

- `worker,worker` 自比空 diff = **机制 GO**（归一化完备、capture/diff 无误报）。
- `worker,elixir` 双跑 = parity 现状：新 Elixir 尚未实现 #2/#5/#8/#9，diff 会如实
  列出缺口（404/缺帧）；随各 issue 落地 diff 收敛。cutover 门槛（spec §12）=
  conformance 全绿 + diff 空（除归一化字段）+ S3 E2E + 读路径观测达标。

## 已知限制 / 后续

- `event_state.per_channel` 这类 **key 为服务端 id** 的 map：key 归一化遇碰撞时按
  出现顺序加 `#N` 后缀；同规模 map 可 diff，key 顺序不同可能产生值错位（当前
  scenario 单频道不触发）。后续可按 value 排序做稳定化。
- fanout 为 best-effort（§10.5）：lease 注册竞态用 1s 宽限 + 15s 等待兜底；若
  `worker,worker` 自比出现偶发超时，先查 miniflare alarm 负载再放宽。
- opaque cursor 内嵌易变值时依赖「内嵌 UUID/TS 替换」覆盖；出现新形态（如 base64
  编码 cursor）时在 self-test 暴露后补规则。
