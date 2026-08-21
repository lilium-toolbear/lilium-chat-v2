/**
 * Conformance harness CLI (spec §7, issue #1).
 *
 *   npm run conformance -- self-test
 *     Fast CI proof: the scenario runs against two independent in-process
 *     mock targets with randomized volatile values; normalized captures must
 *     diff empty (no false positives from {{UUID}}/{{TS}} normalization).
 *
 *   npm run conformance -- run --targets worker,elixir
 *     The real gate: same scenario against the old Worker (wrangler dev,
 *     fresh miniflare state) and the new Elixir app (clean chat_v2.*),
 *     normalized diff + read-path observations (§7.5). Exit 0 = parity.
 *
 *   npm run conformance -- run --targets worker,worker
 *     Self-diff of the real old Worker (two fresh miniflare states) — the
 *     strongest mechanism proof that normalization is complete.
 */

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "pg";
import { captureForDiff, diffCaptures } from "./diff.js";
import { normalizeCapture } from "./normalize.js";
import { runScenario, collectKnownClientIds, type Endpoint } from "./runner.js";
import { writeReports } from "./report.js";
import type { Capture, Scenario } from "./types.js";
import { bootstrapSendFanout } from "../scenarios/bootstrap-send-fanout.js";
import { MockTarget } from "./targets/mock.js";
import { WorkerTarget } from "./targets/worker.js";
import { ElixirTarget } from "./targets/elixir.js";
import type { ConformanceTarget } from "./targets/types.js";

const HERE = fileURLToPath(import.meta.url);
const CONFORMANCE_DIR = resolve(HERE, "..", ".."); // .../conformance
const REPO_ROOT = resolve(CONFORMANCE_DIR, "..");

const SCENARIOS: Record<string, Scenario> = {
  "bootstrap-send-fanout": bootstrapSendFanout,
};

const DEFAULT_JWT_SECRET = "test-jwt-secret-do-not-use-in-prod"; // old repo test secret
const DEFAULT_DB_URL = "postgres://chat:chat@127.0.0.1:5432/lilium_chat_dev";
const DEFAULT_OLD_REPO = resolve(REPO_ROOT, "..", "lilium-chat");

function parseArgs(argv: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a) continue;
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        out[key] = next;
        i++;
      } else {
        out[key] = "1";
      }
    }
  }
  return out;
}

async function runAgainstTarget(target: ConformanceTarget, scenario: Scenario, jwtSecret: string): Promise<Capture> {
  const probe = target.readProbe();
  if (probe) await probe.install();
  try {
    return await runScenario(scenario, target.endpoint(), {
      jwtSecret,
      readProbe: probe,
    });
  } finally {
    if (probe) await probe.uninstall().catch((err) => console.error(`[warn] probe uninstall failed: ${String(err)}`));
  }
}

async function selfTest(): Promise<number> {
  const scenario = SCENARIOS["bootstrap-send-fanout"];
  if (!scenario) return 2;
  const knownClientIds = collectKnownClientIds(scenario);

  console.log(`self-test: scenario=${scenario.name} (two independent mock instances, randomized volatile values)`);
  const a = new MockTarget({ name: "mock-a" });
  const b = new MockTarget({ name: "mock-b" });
  let exitCode = 0;
  try {
    await a.start();
    await b.start();
    await a.reset();
    await b.reset();
    const captureA = await runAgainstTarget(a, scenario, DEFAULT_JWT_SECRET);
    const captureB = await runAgainstTarget(b, scenario, DEFAULT_JWT_SECRET);

    const normA = normalizeCapture(captureA, { knownClientIds });
    const normB = normalizeCapture(captureB, { knownClientIds });
    const { diffs, truncated } = diffCaptures(captureForDiff(normA), captureForDiff(normB));

    if (diffs.length === 0) {
      console.log("self-test: PASS — normalized captures identical (normalizer has no false positives).");
    } else {
      exitCode = 1;
      console.error(`self-test: FAIL — ${diffs.length} unexpected difference(s):`);
      for (const d of diffs.slice(0, 20)) {
        console.error(`  @ ${d.path}\n      a: ${JSON.stringify(d.left)}\n      b: ${JSON.stringify(d.right)}`);
      }
    }
    void truncated;
  } catch (err) {
    console.error(`self-test: ERROR — ${err instanceof Error ? err.stack ?? err.message : String(err)}`);
    exitCode = 2;
  } finally {
    await a.stop().catch(() => {});
    await b.stop().catch(() => {});
  }
  return exitCode;
}

interface TargetSpec {
  target: ConformanceTarget;
  label: string;
}

function buildTargets(specs: string[], args: Record<string, string>): TargetSpec[] {
  const jwtSecret = process.env.CONFORMANCE_JWT_SECRET ?? DEFAULT_JWT_SECRET;
  const dbUrl = process.env.CONFORMANCE_DB_URL ?? DEFAULT_DB_URL;
  const oldRepo = resolve(process.env.CONFORMANCE_OLD_REPO ?? DEFAULT_OLD_REPO);
  const out: TargetSpec[] = [];
  let workerPort = Number(args["worker-port"] ?? 8791);

  for (const spec of specs) {
    const [kind, param] = spec.includes(":") ? [spec.slice(0, spec.indexOf(":")), spec.slice(spec.indexOf(":") + 1)] : [spec, undefined];
    switch (kind) {
      case "worker": {
        const port = param ? Number(param) : workerPort;
        workerPort = Math.max(workerPort, port) + 1; // next duplicate gets a fresh port
        out.push({
          label: `worker@${port}`,
          target: new WorkerTarget({ repoDir: oldRepo, port, name: `worker@${port}`, jwtSecret }),
        });
        break;
      }
      case "elixir": {
        const baseUrl = param ?? args["elixir-url"] ?? "http://127.0.0.1:4000";
        out.push({
          label: `elixir@${baseUrl}`,
          target: new ElixirTarget({ baseUrl, dbUrl, name: `elixir@${baseUrl}` }),
        });
        break;
      }
      case "mock": {
        out.push({ label: kind, target: new MockTarget({ name: kind }) });
        break;
      }
      default:
        throw new Error(`unknown target kind \`${kind}\` (expected worker | elixir | mock)`);
    }
  }
  return out;
}

/**
 * Seed profile rows for scenario actors in the shared dev PG BEFORE any
 * target runs. Both targets resolve profiles from public.users (old Worker
 * via Hyperdrive, new Elixir directly) — seeding once here keeps them
 * consistent regardless of target order. Best-effort: if PG is unreachable
 * the run continues and both sides fall back identically (still diffable).
 */
async function seedProfiles(dbUrl: string): Promise<void> {
  const sql = await readFile(resolve(CONFORMANCE_DIR, "fixtures", "seed-users.sql"), "utf8");
  const client = new Client({ connectionString: dbUrl });
  try {
    await client.connect();
    await client.query(sql);
  } catch (err) {
    console.warn(`[warn] profile seeding skipped (${err instanceof Error ? err.message : String(err)})`);
  } finally {
    await client.end().catch(() => {});
  }
}

async function run(targetsSpec: string, args: Record<string, string>): Promise<number> {
  const scenarioName = args.scenario ?? "bootstrap-send-fanout";
  const scenario = SCENARIOS[scenarioName];
  if (!scenario) {
    console.error(`unknown scenario \`${scenarioName}\` (available: ${Object.keys(SCENARIOS).join(", ")})`);
    return 2;
  }
  const jwtSecret = process.env.CONFORMANCE_JWT_SECRET ?? DEFAULT_JWT_SECRET;
  const knownClientIds = collectKnownClientIds(scenario);

  await seedProfiles(process.env.CONFORMANCE_DB_URL ?? DEFAULT_DB_URL);

  let built: TargetSpec[];
  try {
    built = buildTargets(targetsSpec.split(",").map((s) => s.trim()).filter(Boolean), args);
  } catch (err) {
    console.error(`target setup error: ${err instanceof Error ? err.message : String(err)}`);
    return 2;
  }

  const captures: Array<{ spec: TargetSpec; capture?: Capture; error?: string }> = [];
  for (const spec of built) {
    process.stdout.write(`[${spec.label}] reset + start … `);
    try {
      await spec.target.reset();
      await spec.target.start();
      const capture = await runAgainstTarget(spec.target, scenario, jwtSecret);
      captures.push({ spec, capture });
      console.log(`done (${capture.steps.length} steps)`);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      captures.push({ spec, error: message });
      console.log(`FAILED: ${message.split("\n")[0]}`);
    } finally {
      await spec.target.stop().catch(() => {});
    }
  }

  // Normalize + diff the first two SUCCESSFUL captures (a failed target must
  // not shift which pair is compared).
  const successful = captures.filter((c): c is { spec: TargetSpec; capture: Capture } => Boolean(c.capture));
  if (successful.length < 2) {
    console.error("cannot diff: fewer than two targets produced a capture.");
    return 2;
  }
  const [leftEntry, rightEntry] = successful;
  if (!leftEntry || !rightEntry) {
    console.error("cannot diff: no successful captures.");
    return 2;
  }
  const left = normalizeCapture(leftEntry.capture, { knownClientIds });
  const right = normalizeCapture(rightEntry.capture, { knownClientIds });
  const { diffs, truncated } = diffCaptures(captureForDiff(left), captureForDiff(right));

  // §7.5 read-path observations (per target, not part of the wire diff).
  const observations: Record<string, unknown> = {};
  let observationsOk = true;
  for (const c of captures) {
    if (!c.capture) continue;
    const probeResults = c.capture.steps
      .filter((s) => s.readObservation)
      .map((s) => ({ step: s.name, ok: s.readObservation!.ok, hiddenWrites: s.readObservation!.hiddenWrites.length, queryCount: s.readObservation!.queryCount }));
    if (probeResults.length > 0) {
      observations[c.spec.label] = probeResults;
      if (!probeResults.every((p) => p.ok)) observationsOk = false;
    }
  }

  const report = writeReports(resolve(CONFORMANCE_DIR, "reports"), left, right, diffs, truncated, {
    mode: "dual-run",
    targets: built.map((b) => b.label),
    readPathObservations: observations,
    captureErrors: Object.fromEntries(captures.map((c) => [c.spec.label, c.error ?? null])),
  });

  const { renderDiffReport } = await import("./report.js");
  console.log("");
  console.log(renderDiffReport(left, right, diffs, truncated));
  if (Object.keys(observations).length > 0) {
    console.log("");
    console.log("read-path observations (§7.5):");
    for (const [label, results] of Object.entries(observations)) {
      for (const r of results as Array<Record<string, unknown>>) {
        console.log(`  ${label} / ${r.step}: ok=${r.ok} hiddenWrites=${r.hiddenWrites} queryCount=${r.queryCount ?? "n/a"}`);
      }
    }
  }
  console.log("");
  console.log(`report: ${report.txtPath}`);

  const gate = diffs.length === 0 && observationsOk;
  console.log(gate ? "\nGATE: GO — parity within normalized fields, read-path observations pass." : "\nGATE: NO-GO — see diff / observations above.");
  return gate ? 0 : 1;
}

async function main(): Promise<number> {
  const [cmd, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);
  switch (cmd) {
    case "self-test":
      return selfTest();
    case "run":
      if (!args.targets) {
        console.error("usage: conformance run --targets worker,elixir [--scenario bootstrap-send-fanout]");
        return 2;
      }
      return run(args.targets, args);
    default:
      console.log(`conformance harness (spec §7 / issue #1)

commands:
  self-test                            mock-target self-diff (CI, no external deps)
  run --targets worker,elixir          dual-run gate (old Worker vs new Elixir)
  run --targets worker,worker          old-Worker self-diff (mechanism proof)

options:
  --scenario <name>                    default: bootstrap-send-fanout
  --worker-port <port>                 first worker target port (default 8791)
  --elixir-url <url>                   default http://127.0.0.1:4000

env:
  CONFORMANCE_JWT_SECRET               HS256 secret for scenario actor JWTs
  CONFORMANCE_DB_URL                   shared dev PG (default ${DEFAULT_DB_URL})
  CONFORMANCE_OLD_REPO                 path to the old lilium-chat repo`);
      return cmd ? 2 : 0;
  }
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.stack ?? err.message : String(err));
    process.exitCode = 2;
  });
