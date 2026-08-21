/**
 * Structural diff of two normalized captures (spec §7.1/§7.2).
 *
 * Compares value-by-value and reports every difference as a path entry.
 * Empty result = the two targets are wire-identical modulo normalized fields.
 */

import { MISSING, type DiffEntry } from "./types.js";

const MAX_ENTRIES = 500;

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function diffValues(left: unknown, right: unknown, path = "$"): DiffEntry[] {
  const entries: DiffEntry[] = [];
  if (left === MISSING || right === MISSING) {
    if (left === MISSING && right === MISSING) return entries;
    entries.push({ path, left: left === MISSING ? undefined : left, right: right === MISSING ? undefined : right });
    return entries;
  }
  if (Array.isArray(left) && Array.isArray(right)) {
    const len = Math.max(left.length, right.length);
    for (let i = 0; i < len; i++) {
      entries.push(
        ...diffValues(i < left.length ? left[i] : MISSING, i < right.length ? right[i] : MISSING, `${path}[${i}]`),
      );
    }
    return entries;
  }
  if (isPlainObject(left) && isPlainObject(right)) {
    const keys = new Set([...Object.keys(left), ...Object.keys(right)]);
    for (const key of [...keys].sort()) {
      const childPath = `${path}.${key}`;
      entries.push(
        ...diffValues(key in left ? left[key] : MISSING, key in right ? right[key] : MISSING, childPath),
      );
    }
    return entries;
  }
  if (typeof left !== typeof right || Array.isArray(left) !== Array.isArray(right)) {
    entries.push({ path, left, right });
    return entries;
  }
  if (left !== right) {
    // NaN safety (should not occur on the wire).
    const bothNaN = typeof left === "number" && typeof right === "number" && Number.isNaN(left) && Number.isNaN(right);
    if (!bothNaN) entries.push({ path, left, right });
  }
  return entries;
}

/** Diff two normalized captures, capped so a fully divergent run stays readable. */
export function diffCaptures(left: unknown, right: unknown): { diffs: DiffEntry[]; truncated: boolean } {
  const all = diffValues(left, right);
  if (all.length <= MAX_ENTRIES) return { diffs: all, truncated: false };
  return { diffs: all.slice(0, MAX_ENTRIES), truncated: true };
}

/**
 * Project a capture to what is comparable across targets. Per-target harness
 * metadata (`target` name, `readObservation` per spec §7.5) is acceptance
 * data for ONE target, not wire payload — it stays in the JSON report but is
 * excluded from the differential diff.
 */
export function captureForDiff<T extends { steps?: unknown[] }>(capture: T): Record<string, unknown> {
  const out: Record<string, unknown> = { ...(capture as Record<string, unknown>) };
  delete out.target;
  if (Array.isArray(capture.steps)) {
    out.steps = (capture.steps as Array<Record<string, unknown>>).map((step) => {
      const { readObservation: _obs, ...rest } = step;
      return rest;
    });
  }
  return out;
}
