/**
 * Old-Worker target: runs the reference Cloudflare Worker locally via
 * `wrangler dev` (spec §7.1a) with a FRESH miniflare state directory per run
 * ("clean miniflare state"). The old repo is referenced in place — nothing in
 * it is modified; wrangler's config + .dev.vars live in THIS package and
 * point at the old repo's entrypoint.
 */

import { execFile } from "node:child_process";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { Endpoint } from "../runner.js";
import type { ReadPathProbe } from "../read-path.js";
import type { ConformanceTarget } from "./types.js";

const HERE = dirname(fileURLToPath(import.meta.url)); // conformance/src/targets
export const CONFORMANCE_DIR = resolve(HERE, "..", "..");

export interface WorkerTargetOptions {
  /** Absolute path to the old repo (lilium-chat). */
  repoDir: string;
  port?: number;
  name?: string;
  /** JWT secret written into .dev.vars for this run. */
  jwtSecret: string;
  /** Miniflare state root; a fresh subdirectory is used per start(). */
  stateRoot?: string;
  /** Readiness timeout. */
  readyTimeoutMs?: number;
}

export class WorkerTarget implements ConformanceTarget {
  private child: ChildProcess | null = null;
  private stderrTail = "";
  private persistDir: string | null = null;

  readonly name: string;
  private readonly port: number;
  private readonly readyTimeoutMs: number;

  constructor(private readonly opts: WorkerTargetOptions) {
    this.name = opts.name ?? "worker";
    this.port = opts.port ?? 8791;
    this.readyTimeoutMs = opts.readyTimeoutMs ?? 120_000;
  }

  endpoint(): Endpoint {
    return { name: this.name, httpBase: `http://127.0.0.1:${this.port}`, wsBase: `ws://127.0.0.1:${this.port}` };
  }

  private get configPath(): string {
    return join(CONFORMANCE_DIR, "wrangler.conformance.jsonc");
  }

  private wranglerEntry(): string {
    const entry = join(this.opts.repoDir, "node_modules", "wrangler", "bin", "wrangler.js");
    if (!existsSync(entry)) {
      throw new Error(
        `wrangler not found at ${entry} — run \`npm ci\` in the old repo (${this.opts.repoDir}) first`,
      );
    }
    return entry;
  }

  async reset(): Promise<void> {
    // Clean miniflare state: drop any previous persist dir.
    if (this.persistDir) {
      rmSync(this.persistDir, { recursive: true, force: true });
      this.persistDir = null;
    }
  }

  async start(): Promise<void> {
    if (this.child) return;

    // .dev.vars next to the config (wrangler discovers it from CWD/config dir).
    const devVars = join(CONFORMANCE_DIR, ".dev.vars");
    writeFileSync(
      devVars,
      [
        `JWT_SECRET=${this.opts.jwtSecret}`,
        "ALLOW_INTERNAL_TEST_ROUTES=1",
        // Conformance fake-S3 (issue #27 batch B/C): the old Worker's SigV4
        // client (src/s3/client.ts createS3Client) reads the access key +
        // secret even though signing is local — missing values surface as a
        // generic 503 CHAT_WORKER_UNAVAILABLE via the error handler.
        "S3_ACCESS_KEY_ID=conformance-access-key",
        "S3_SECRET_ACCESS_KEY=conformance-secret-key",
        "",
      ].join("\n"),
      "utf8",
    );

    const stateRoot = this.opts.stateRoot ?? join(CONFORMANCE_DIR, "state");
    this.persistDir = join(stateRoot, `worker-${Date.now()}`);
    mkdirSync(this.persistDir, { recursive: true });

    // Same invocation the old repo's `npm run dev` uses, plus an explicit
    // config (local Hyperdrive connection + test vars) and a fresh persist
    // dir for a clean miniflare state.
    const args = [
      this.wranglerEntry(),
      "dev",
      "--config",
      this.configPath,
      "--port",
      String(this.port),
      "--persist-to",
      this.persistDir,
    ];

    this.stderrTail = "";
    const child = spawn(process.execPath, args, {
      cwd: CONFORMANCE_DIR,
      env: { ...process.env },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
      detached: process.platform !== "win32", // POSIX: own process group for tree kill
    });
    this.child = child;
    child.stdout?.on("data", () => undefined); // keep wrangler's banner out of our logs
    child.stderr?.on("data", (d: Buffer) => {
      this.stderrTail = (this.stderrTail + d.toString()).slice(-8000);
    });
    child.on("error", (err) => {
      // spawn-level failure (e.g. node missing) — surface on next readiness check
      this.spawnError = err;
    });

    try {
      await this.waitForReady();
    } catch (err) {
      await this.stop().catch(() => {});
      throw err;
    }
  }

  private spawnError: Error | null = null;

  private async waitForReady(): Promise<void> {
    const deadline = Date.now() + this.readyTimeoutMs;
    let lastErr = "";
    while (Date.now() < deadline) {
      if (this.spawnError) throw new Error(`wrangler spawn failed: ${this.spawnError.message}\n${this.stderrTail}`);
      // Early exit detection without a side promise (an unhandled rejection
      // here would crash the harness process on Windows).
      const child = this.child;
      if (child && (child.exitCode !== null || child.signalCode !== null)) {
        throw new Error(
          `wrangler dev exited early (code=${child.exitCode} signal=${child.signalCode})\n${this.stderrTail}`,
        );
      }
      try {
        const res = await fetch(`http://127.0.0.1:${this.port}/api/chat/bootstrap`, { method: "GET" });
        // Any HTTP response (401 envelope included) means the Worker is up.
        void res.status;
        await res.body?.cancel().catch(() => {});
        return;
      } catch (err) {
        lastErr = err instanceof Error ? err.message : String(err);
      }
      await new Promise((r) => setTimeout(r, 500));
    }
    throw new Error(`worker target not ready after ${this.readyTimeoutMs}ms (${lastErr})\n${this.stderrTail}`);
  }

  async stop(): Promise<void> {
    const child = this.child;
    this.child = null;
    const pid = child?.pid;
    if (!child || pid === undefined) return;
    await new Promise<void>((resolvePromise) => {
      const done = () => resolvePromise();
      child.once("exit", done);
      try {
        if (process.platform === "win32") {
          execFile("taskkill.exe", ["/PID", String(pid), "/T", "/F"], () => done());
        } else {
          process.kill(-pid, "SIGTERM"); // requires detached group; fallback below
          setTimeout(() => {
            try {
              child.kill("SIGKILL");
            } catch {
              /* already gone */
            }
            done();
          }, 5000);
        }
      } catch {
        done();
      }
    });
  }

  readProbe(): ReadPathProbe | null {
    // §7.5 acceptance targets the NEW implementation's PG read path (D15).
    // The old Worker's DO state lives in miniflare; its only PG traffic is
    // profile resolution on the shared instance — not a probe target here.
    return null;
  }
}
