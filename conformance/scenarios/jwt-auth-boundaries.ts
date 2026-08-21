/**
 * JWT auth boundary conformance (issue #2, acceptance criterion A6).
 *
 * Exercises every ToolBear JWT rule of contract §2.1 against
 * `GET /api/chat/channels` — the one route that exists on BOTH targets at
 * this phase:
 *
 *   valid user token            → 200 (empty-state shape)
 *   admin claim                 → 200 (accepted, same as user)
 *   client_id present           → 401 MACHINE_TOKEN_NOT_ALLOWED
 *   managed_session === true    → 403 SESSION_NOT_ALLOWED
 *   owner_user_id mismatch      → 403 SESSION_NOT_ALLOWED
 *   no Authorization header     → 401 UNAUTHORIZED "Not authenticated"
 *   malformed bearer token      → 401 UNAUTHORIZED "Invalid or expired token"
 *   expired token (exp < now)   → 401 UNAUTHORIZED "Invalid or expired token"
 *
 * All inputs are deterministic; tokens are volatile and masked to {{JWT}} by
 * the normalizer, so both targets diff on status + error envelope + headers.
 */

import type { Scenario } from "../src/types.js";

const USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f";

export const jwtAuthBoundaries: Scenario = {
  name: "jwt-auth-boundaries",
  description:
    "JWT auth boundaries (contract §2.1): valid/admin accepted, client_id / managed_session / owner mismatch rejected, no-token / malformed / expired → UNAUTHORIZED.",
  actors: {
    user: { userId: USER_ID },
    admin: { userId: USER_ID, jwtClaims: { admin: true } },
    machine: { userId: USER_ID, jwtClaims: { client_id: "conformance-client" } },
    managed: { userId: USER_ID, jwtClaims: { managed_session: true } },
    delegated: { userId: USER_ID, jwtClaims: { owner_user_id: "delegated-owner-0001" } },
    expired: { userId: USER_ID, jwtExpSeconds: -3600 },
  },
  steps: [
    {
      kind: "http",
      actor: "user",
      name: "valid-user-token-accepted",
      method: "GET",
      path: "/api/chat/channels",
    },
    {
      kind: "http",
      actor: "admin",
      name: "admin-claim-accepted",
      method: "GET",
      path: "/api/chat/channels",
    },
    {
      kind: "http",
      actor: "machine",
      name: "client-id-rejected",
      method: "GET",
      path: "/api/chat/channels",
    },
    {
      kind: "http",
      actor: "managed",
      name: "managed-session-rejected",
      method: "GET",
      path: "/api/chat/channels",
    },
    {
      kind: "http",
      actor: "delegated",
      name: "owner-mismatch-rejected",
      method: "GET",
      path: "/api/chat/channels",
    },
    {
      kind: "http",
      actor: "user",
      name: "no-token-unauthenticated",
      method: "GET",
      path: "/api/chat/channels",
      headers: { Authorization: null },
    },
    {
      kind: "http",
      actor: "user",
      name: "malformed-token-rejected",
      method: "GET",
      path: "/api/chat/channels",
      headers: { Authorization: "Bearer not-a-jwt" },
    },
    {
      kind: "http",
      actor: "expired",
      name: "expired-token-rejected",
      method: "GET",
      path: "/api/chat/channels",
    },
  ],
};
