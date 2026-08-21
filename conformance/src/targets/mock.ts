/**
 * Mock target: an in-process, contract-faithful implementation of the
 * scenario's surface (bootstrap / channels / WS live fanout).
 *
 * Every server-minted id and timestamp is RANDOMIZED per instance, so two
 * independent mock instances produce different raw captures. The self-test
 * asserts their NORMALIZED captures are identical — proving the
 * normalizer+differ pipeline has no false positives (acceptance criterion 2)
 * without needing wrangler or a database.
 *
 * Identity: the mock decodes (without verifying) the JWT `sub` claim from
 * the Authorization header / WS subprotocol and echoes it as `me.user_id`,
 * exactly like the real Worker would after verification.
 */

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { randomUUID } from "node:crypto";
import type { Socket } from "node:net";
import WebSocket, { WebSocketServer, type RawData } from "ws";
import type { Endpoint } from "../runner.js";
import type { ReadPathProbe } from "../read-path.js";
import type { ConformanceTarget } from "./types.js";

const DISPLAY_NAME = "Conformance Alice";

interface MockMessage {
  message_id: string;
  command_id: string;
  channel_id: string;
  text: string;
  created_at: string;
}

interface MockChannel {
  channel_id: string;
  title: string;
  visibility: string;
  created_at: string;
  updated_at: string;
  /** When the channel becomes visible in list/bootstrap (async projection). */
  visibleAt: number;
  messages: MockMessage[];
}

export interface MockTargetOptions {
  port?: number;
  name?: string;
}

/** Decode a JWT payload without verification (harness-internal fixture only). */
function jwtSub(token: string | undefined): string | null {
  if (!token) return null;
  try {
    const parts = token.split(".");
    const payloadPart = parts[1];
    if (!payloadPart) return null;
    const payload = JSON.parse(Buffer.from(payloadPart, "base64url").toString("utf8")) as { sub?: string };
    return typeof payload.sub === "string" ? payload.sub : null;
  } catch {
    return null;
  }
}

export class MockTarget implements ConformanceTarget {
  private server: Server | null = null;
  private wss: WebSocketServer | null = null;
  private channels = new Map<string, MockChannel>();
  private liveSessions = new Set<WebSocket>();

  readonly name: string;
  private readonly port: number;

  constructor(opts: MockTargetOptions = {}) {
    this.name = opts.name ?? "mock";
    this.port = opts.port ?? 0; // 0 → ephemeral
  }

  endpoint(): Endpoint {
    const p = this.actualPort;
    return { name: this.name, httpBase: `http://127.0.0.1:${p}`, wsBase: `ws://127.0.0.1:${p}` };
  }

  private get actualPort(): number {
    const server = this.server;
    if (!server) return this.port;
    const addr = server.address();
    if (addr && typeof addr === "object") return addr.port;
    return this.port;
  }

  async reset(): Promise<void> {
    this.channels.clear();
  }

  async start(): Promise<void> {
    if (this.server) return;
    const server = createServer((req, res) => void this.handleHttp(req, res));
    const wss = new WebSocketServer({ noServer: true });
    this.wss = wss;
    server.on("upgrade", (req, socket, head) => {
      if (req.url !== "/api/chat/ws") {
        socket.destroy();
        return;
      }
      const origin = req.headers.origin ?? "";
      const protocols = parseSubprotocols(req.headers["sec-websocket-protocol"]);
      const bearer = protocols.find((p) => p.startsWith("bearer."));
      if (origin !== "https://lilium.kuma.homes" || !protocols.includes("lilium.chat.v2") || !bearer) {
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      const sub = jwtSub(bearer.slice("bearer.".length)) ?? "unknown-user";
      wss.handleUpgrade(req, socket, head, (ws) => {
        (ws as unknown as { __conformanceSub?: string }).__conformanceSub = sub;
        void this.handleWs(ws);
      });
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(this.port, "127.0.0.1", () => resolve());
    });
    this.server = server;
  }

  async stop(): Promise<void> {
    for (const ws of this.liveSessions) ws.close();
    this.liveSessions.clear();
    this.wss?.close();
    if (this.server) await new Promise<void>((resolve) => this.server!.close(() => resolve()));
    this.server = null;
    this.wss = null;
  }

  readProbe(): ReadPathProbe | null {
    return null; // no PG behind the mock
  }

  // -------------------------------------------------------------------------

  private nowIso(): string {
    return new Date().toISOString();
  }

  private visibleChannels(): MockChannel[] {
    const t = Date.now();
    return [...this.channels.values()].filter((c) => c.visibleAt <= t);
  }

  private lastEventId(ch: MockChannel): string | null {
    const last = ch.messages[ch.messages.length - 1];
    return last ? last.message_id : null; // mock: event id ≈ message id (volatile either way)
  }

  private messageProjection(sub: string, ch: MockChannel, m: MockMessage) {
    return {
      message_id: m.message_id,
      command_id: m.command_id,
      channel_id: ch.channel_id,
      sender: { kind: "user", user: { user_id: sub, display_name: DISPLAY_NAME, avatar_url: null } },
      type: "text",
      format: "plain",
      status: "normal",
      stream_state: "final",
      text: m.text,
      reply_to: null,
      reply_snapshot: null,
      attachments: [],
      components: [],
      mentions: [],
      created_at: m.created_at,
      updated_at: m.created_at,
      edited_at: null,
      deleted_at: null,
      recalled_at: null,
    };
  }

  private channelSummary(ch: MockChannel) {
    const last = ch.messages[ch.messages.length - 1];
    return {
      channel_id: ch.channel_id,
      kind: "channel",
      visibility: ch.visibility,
      title: ch.title,
      topic: null,
      avatar_url: null,
      member_count: 1,
      status: "active",
      created_at: ch.created_at,
      updated_at: ch.updated_at,
      unread_count: 0,
      last_read_event_id: null,
      last_message_preview: last ? `${DISPLAY_NAME}: ${last.text}` : null,
      last_message_at: last ? last.created_at : null,
      last_event_id: this.lastEventId(ch),
      role: "owner",
    };
  }

  private bootstrapBody(sub: string, channelId?: string) {
    const visible = this.visibleChannels();
    const active = channelId
      ? visible.find((c) => c.channel_id === channelId) ?? null
      : visible[visible.length - 1] ?? null;
    return {
      me: { user_id: sub, display_name: DISPLAY_NAME, avatar_url: null },
      channels: visible.map((c) => this.channelSummary(c)),
      active_channel: active
        ? {
            channel_id: active.channel_id,
            kind: "channel",
            visibility: active.visibility,
            title: active.title,
            topic: null,
            avatar_url: null,
            member_count: 1,
            role: "owner",
            status: "active",
            created_at: active.created_at,
            updated_at: active.updated_at,
          }
        : null,
      messages: {
        items: active ? active.messages.map((m) => this.messageProjection(sub, active, m)) : [],
        next_cursor: null,
      },
      channel_pins: [],
      event_state: { per_channel: Object.fromEntries(visible.map((c) => [c.channel_id, this.lastEventId(c)])) },
    };
  }

  private handleHttp(req: IncomingMessage, res: ServerResponse): void {
    const url = new URL(req.url ?? "/", "http://localhost");
    const requestId = `req_${randomUUID()}`;
    const auth = req.headers.authorization ?? "";
    const sub = jwtSub(auth.replace(/^Bearer\s+/i, "")) ?? "unknown-user";
    const send = (status: number, body: unknown): void => {
      res.writeHead(status, { "Content-Type": "application/json", "X-Request-Id": requestId });
      res.end(JSON.stringify(body));
    };

    if (req.method === "GET" && url.pathname === "/api/chat/bootstrap") {
      const channelId = url.searchParams.get("channel_id") ?? undefined;
      return send(200, this.bootstrapBody(sub, channelId));
    }
    if (req.method === "GET" && url.pathname === "/api/chat/channels") {
      return send(200, { items: this.visibleChannels().map((c) => this.channelSummary(c)), next_cursor: null });
    }
    if (req.method === "POST" && url.pathname === "/api/chat/channels") {
      let raw = "";
      req.on("data", (d) => (raw += d));
      req.on("end", () => {
        const body = JSON.parse(raw || "{}") as { title?: string; visibility?: string };
        if (typeof body.title !== "string" || body.title.trim() === "") {
          return send(422, { error: { code: "INVALID_MESSAGE", message: "title is required", retryable: false } });
        }
        const now = this.nowIso();
        const ch: MockChannel = {
          channel_id: randomUUID(),
          title: body.title,
          visibility: body.visibility ?? "private",
          created_at: now,
          updated_at: now,
          visibleAt: Date.now() + 200 + Math.floor(Math.random() * 500), // async projection delay
          messages: [],
        };
        this.channels.set(ch.channel_id, ch);
        return send(201, {
          channel: {
            channel_id: ch.channel_id,
            kind: "channel",
            visibility: ch.visibility,
            title: ch.title,
            topic: null,
            avatar_url: null,
            member_count: 1,
            status: "active",
            created_at: ch.created_at,
            updated_at: ch.updated_at,
          },
          joined_at: now,
        });
      });
      return;
    }
    return send(404, { error: { code: "CHANNEL_NOT_FOUND", message: "not found", retryable: false } });
  }

  private async handleWs(ws: WebSocket): Promise<void> {
    this.liveSessions.add(ws);
    ws.on("message", (data: RawData) => {
      let frame: Record<string, unknown>;
      try {
        frame = JSON.parse(data.toString());
      } catch {
        return;
      }
      if (frame.frame_type !== "command") return;
      const command = String(frame.command ?? "");
      const commandId = String(frame.command_id ?? "");

      if (command === "session.live_start") {
        ws.send(
          JSON.stringify({
            frame_type: "command_ack",
            command,
            command_id: commandId,
            status: "committed",
            payload: {
              session_id: randomUUID(),
              subscribed_channel_count: this.visibleChannels().length,
              lease_expires_at: new Date(Date.now() + 10 * 60_000).toISOString(),
            },
          }),
        );
        return;
      }

      if (command === "message.send") {
        const payload = (frame.payload ?? {}) as Record<string, unknown>;
        const channelId = String(frame.channel_id ?? "");
        const ch = this.channels.get(channelId);
        if (!ch) {
          ws.send(
            JSON.stringify({
              frame_type: "command_error",
              command_id: commandId,
              error: { code: "CHANNEL_NOT_FOUND", message: "channel not found", retryable: false },
            }),
          );
          return;
        }
        const now = this.nowIso();
        const msg: MockMessage = {
          message_id: randomUUID(),
          command_id: commandId,
          channel_id: channelId,
          text: String(payload.text ?? ""),
          created_at: now,
        };
        ch.messages.push(msg);
        ch.updated_at = now;
        const eventId = randomUUID();
        ws.send(
          JSON.stringify({
            frame_type: "command_ack",
            command,
            command_id: commandId,
            status: "committed",
            payload: { channel_id: channelId, event_id: eventId, message: this.messageProjection(subOf(ws), ch, msg) },
          }),
        );
        // Fanout: deliver the channel event to live sessions after a short delay.
        const eventFrame = {
          frame_type: "event",
          api_version: "lilium.chat.v1",
          event_id: eventId,
          type: "message.created",
          channel_id: channelId,
          occurred_at: now,
          payload: { channel_id: channelId, event_id: eventId, message: this.messageProjection(subOf(ws), ch, msg) },
        };
        setTimeout(() => {
          for (const s of this.liveSessions) {
            if (s.readyState === WebSocket.OPEN) s.send(JSON.stringify(eventFrame));
          }
        }, 100 + Math.floor(Math.random() * 200));
        return;
      }

      ws.send(
        JSON.stringify({
          frame_type: "command_error",
          command_id: commandId,
          error: { code: "INVALID_COMMAND", message: `unknown command ${command}`, retryable: false },
        }),
      );
    });
    await new Promise<void>((resolve) => {
      ws.on("close", () => {
        this.liveSessions.delete(ws);
        resolve();
      });
    });
  }
}

/** Per-socket identity, stashed at upgrade time by the caller. */
function subOf(ws: WebSocket): string {
  const v = (ws as unknown as { __conformanceSub?: string }).__conformanceSub;
  return v ?? "unknown-user";
}

function parseSubprotocols(header: string | undefined): string[] {
  if (!header) return [];
  return header.split(",").map((s) => s.trim()).filter(Boolean);
}

// Keep the Socket import referenced for type clarity in handleUpgrade.
export type { Socket as _MockSocket };
