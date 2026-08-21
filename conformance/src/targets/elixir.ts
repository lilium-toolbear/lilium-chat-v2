/**
 * New-Elixir target (spec §7.1b): the Phoenix app under test, with a CLEAN
 * `chat_v2.*` schema per run. The app process itself is owned by the dev
 * flow (`scripts/dev.sh server` / `podman compose up`); the harness owns
 * STATE reset and readiness checks, not the app lifecycle.
 *
 * State reset:
 *   1. drop schema chat_v2 (direct PG connection)
 *   2. re-apply Ecto migrations via a one-shot app container
 *      (`podman compose run --rm app mix ecto.migrate`)
 *   3. seed `public.users` profile rows for scenario actors (shared instance,
 *      also consumed by the old Worker's Hyperdrive profile resolution)
 */

import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "pg";
import type { Endpoint } from "../runner.js";
import { PostgresReadPathProbe, type ReadPathProbe } from "../read-path.js";
import { CONFORMANCE_DIR } from "./worker.js";
import type { ConformanceTarget } from "./types.js";

const HERE = dirname(fileURLToPath(import.meta.url)); // conformance/src/targets

export interface ElixirTargetOptions {
  /** Base URL of the running Phoenix app, e.g. http://127.0.0.1:4000. */
  baseUrl: string;
  /** PG connection string for state reset + probes (shared dev instance). */
  dbUrl: string;
  /** Repo root containing docker-compose.yml (lilium-chat-v2). */
  repoDir?: string;
  name?: string;
  readyTimeoutMs?: number;
}

export class ElixirTarget implements ConformanceTarget {
  private probe: PostgresReadPathProbe | null = null;

  readonly name: string;
  private readonly readyTimeoutMs: number;
  private readonly repoDir: string;

  constructor(private readonly opts: ElixirTargetOptions) {
    this.name = opts.name ?? "elixir";
    this.readyTimeoutMs = opts.readyTimeoutMs ?? 30_000;
    this.repoDir = opts.repoDir ?? resolve(HERE, "..", "..", "..");
  }

  endpoint(): Endpoint {
    const base = this.opts.baseUrl.replace(/\/$/, "");
    return {
      name: this.name,
      httpBase: base,
      wsBase: base.replace(/^http/, "ws"),
    };
  }

  async reset(): Promise<void> {
    // 1. Clean business schema (Ecto owns the tables; we own the lifecycle).
    const client = new Client({ connectionString: this.opts.dbUrl });
    await client.connect();
    try {
      await client.query(`DROP SCHEMA IF EXISTS chat_v2 CASCADE`);
    } finally {
      await client.end();
    }

    // 2. Ensure the app container is up (idempotent; a cold start runs its
    //    own `mix ecto.migrate` before phx.server). We do NOT use
    //    `compose run --rm app`: the service pins container_name, which
    //    collides with the running server.
    await this.podman(["compose", "-f", join(this.repoDir, "docker-compose.yml"), "up", "-d", "app"]);

    // 3. Re-apply migrations inside the RUNNING container (idempotent; Ecto
    //    serializes via advisory lock, so a cold-start migration race is safe).
    await this.waitContainerRunning();
    await this.podman(["exec", "lilium_chat_app", "mix", "ecto.migrate"]);

    // 4. Seed profile rows for scenario actors (idempotent upsert).
    const seedSql = await readFile(join(CONFORMANCE_DIR, "fixtures", "seed-users.sql"), "utf8");
    const seedClient = new Client({ connectionString: this.opts.dbUrl });
    await seedClient.connect();
    try {
      await seedClient.query(seedSql);
    } finally {
      await seedClient.end();
    }
  }

  private async waitContainerRunning(timeoutMs = 180_000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    let lastErr = "";
    while (Date.now() < deadline) {
      try {
        const out = await this.podman(["inspect", "-f", "{{.State.Running}}", "lilium_chat_app"]);
        if (out.trim() === "true") return;
        lastErr = `state=${out.trim()}`;
      } catch (err) {
        lastErr = err instanceof Error ? err.message : String(err);
      }
      await new Promise((r) => setTimeout(r, 1000));
    }
    throw new Error(`app container not running after ${timeoutMs}ms: ${lastErr}`);
  }

  private podman(args: string[]): Promise<string> {
    return new Promise((resolvePromise, reject) => {
      execFile(
        "podman",
        args,
        { cwd: this.repoDir, timeout: 300_000, maxBuffer: 16 * 1024 * 1024 },
        (err, stdout, stderr) => {
          if (err) reject(new Error(`podman ${args.join(" ")} failed: ${(stderr || stdout || err.message).slice(-2000)}`));
          else resolvePromise(stdout);
        },
      );
    });
  }

  async start(): Promise<void> {
    const deadline = Date.now() + this.readyTimeoutMs;
    let lastErr = "";
    while (Date.now() < deadline) {
      try {
        const res = await fetch(`${this.opts.baseUrl}/api/chat/bootstrap`, { method: "GET" });
        void res.status; // any HTTP response = app is up
        await res.body?.cancel().catch(() => {});
        return;
      } catch (err) {
        lastErr = err instanceof Error ? err.message : String(err);
      }
      await new Promise((r) => setTimeout(r, 500));
    }
    throw new Error(
      `elixir target not ready at ${this.opts.baseUrl} after ${this.readyTimeoutMs}ms (${lastErr}). ` +
        `Start it first: scripts/dev.sh server (or podman compose up).`,
    );
  }

  async stop(): Promise<void> {
    // App lifecycle is owned by the dev flow; nothing to stop.
  }

  readProbe(): ReadPathProbe | null {
    if (!this.probe) {
      this.probe = new PostgresReadPathProbe({
        connectionString: this.opts.dbUrl,
        schemas: ["chat_v2", "public"], // business tables + profile reads (spec §4)
      });
    }
    return this.probe;
  }
}
