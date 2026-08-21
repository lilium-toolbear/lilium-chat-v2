/**
 * Minimal capturing WebSocket client (RFC 6455 via the `ws` package).
 *
 * The browser-style WebSocket API cannot set request headers, but the Worker
 * validates `Origin` on upgrade (contract §2.1) — so we use `ws`, which
 * allows arbitrary headers. Every received text frame is JSON-parsed (or kept
 * raw with a marker) and handed to the runner's capture buffer in arrival
 * order.
 */

import WebSocket, { type RawData } from "ws";

export interface CapturingWebSocketOptions {
  url: string;
  /** Subprotocols, e.g. ["lilium.chat.v2", "bearer.<jwt>"] (contract §10.1). */
  protocols: string[];
  headers?: Record<string, string>;
  onFrame: (frame: unknown) => void;
  onClose?: (code: number | undefined, reason: string) => void;
}

export class CapturingWebSocket {
  readonly socket: WebSocket;
  private closed = false;

  constructor(opts: CapturingWebSocketOptions) {
    this.socket = new WebSocket(opts.url, opts.protocols, {
      headers: opts.headers ?? {},
      handshakeTimeout: 10_000,
    });
    this.socket.on("message", (data: RawData, isBinary: boolean) => {
      if (isBinary) {
        opts.onFrame({ __binary: `<${(data as Buffer).length} bytes>` });
        return;
      }
      const text = data.toString("utf8");
      try {
        opts.onFrame(JSON.parse(text));
      } catch {
        opts.onFrame({ __unparseable_frame: text });
      }
    });
    this.socket.on("close", (code, reason) => {
      this.closed = true;
      opts.onClose?.(code, reason.toString());
    });
  }

  /** Resolves when the socket is open (101). */
  ready(): Promise<void> {
    return new Promise((resolve, reject) => {
      if (this.socket.readyState === WebSocket.OPEN) return resolve();
      this.socket.once("open", () => resolve());
      this.socket.once("error", (err) => reject(err));
    });
  }

  get negotiatedProtocol(): string | undefined {
    return this.socket.protocol;
  }

  send(frame: unknown): void {
    this.socket.send(JSON.stringify(frame));
  }

  close(code?: number, reason?: string): void {
    if (!this.closed) this.socket.close(code, reason);
  }
}
