/**
 * Target abstraction: anything the harness can reset to empty state, start,
 * hit with HTTP/WS, and observe (spec §7.1).
 */

import type { Endpoint } from "../runner.js";
import type { ReadPathProbe } from "../read-path.js";

export interface ConformanceTarget {
  /** Display name used in captures/reports. */
  name: string;
  endpoint(): Endpoint;
  /** Reset to empty state (clean miniflare state / clean chat_v2.*). */
  reset(): Promise<void>;
  /** Bring the target up and wait for readiness. Idempotent. */
  start(): Promise<void>;
  stop(): Promise<void>;
  /** Read-path observation probe (spec §7.5); null when not applicable. */
  readProbe(): ReadPathProbe | null;
}
