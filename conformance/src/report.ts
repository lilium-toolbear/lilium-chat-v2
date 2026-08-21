/**
 * Conformance report rendering (spec §7).
 *
 * Two artifacts per run:
 *   - `<scenario>__<left>-vs-<right>.txt` — human-readable diff summary
 *   - `<scenario>__<left>-vs-<right>.json` — machine-readable captures + diffs
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Capture, DiffEntry } from "./types.js";

function fmt(value: unknown, max = 240): string {
  if (value === undefined) return "<absent>";
  let s: string;
  try {
    s = JSON.stringify(value);
  } catch {
    s = String(value);
  }
  if (s === undefined) s = "undefined";
  if (s.length > max) s = `${s.slice(0, max)}…(+${s.length - max} chars)`;
  return s;
}

export function renderDiffReport(left: Capture, right: Capture, diffs: DiffEntry[], truncated: boolean): string {
  const lines: string[] = [];
  lines.push("Conformance differential report");
  lines.push(`scenario : ${left.scenario}`);
  lines.push(`left     : ${left.target}`);
  lines.push(`right    : ${right.target}`);
  lines.push("");
  if (diffs.length === 0) {
    lines.push("RESULT: PASS — captures identical after normalization.");
  } else {
    lines.push(`RESULT: FAIL — ${diffs.length} difference(s)${truncated ? " (truncated)" : ""}:`);
    lines.push("");
    for (const d of diffs) {
      lines.push(`  @ ${d.path}`);
      lines.push(`      left : ${fmt(d.left)}`);
      lines.push(`      right: ${fmt(d.right)}`);
    }
    if (truncated) lines.push("  …(diff truncated)");
  }
  return lines.join("\n");
}

export interface WriteReportResult {
  dir: string;
  txtPath: string;
  jsonPath: string;
}

export function writeReports(
  reportsDir: string,
  left: Capture,
  right: Capture,
  diffs: DiffEntry[],
  truncated: boolean,
  extra?: Record<string, unknown>,
): WriteReportResult {
  mkdirSync(reportsDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  // Target labels may contain URL characters (:) that are illegal in file
  // names on Windows — sanitize for the artifact name only.
  const safeName = (s: string): string => s.replace(/[\\/:*?"<>|@]/g, "-");
  const base = `${left.scenario}__${safeName(left.target)}-vs-${safeName(right.target)}__${stamp}`;
  const txtPath = join(reportsDir, `${base}.txt`);
  const jsonPath = join(reportsDir, `${base}.json`);
  writeFileSync(txtPath, renderDiffReport(left, right, diffs, truncated) + "\n", "utf8");
  writeFileSync(
    jsonPath,
    JSON.stringify({ generatedAt: new Date().toISOString(), left, right, diffs, truncated, ...(extra ?? {}) }, null, 2),
    "utf8",
  );
  return { dir: reportsDir, txtPath, jsonPath };
}
