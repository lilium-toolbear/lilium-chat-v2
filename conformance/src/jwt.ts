/**
 * Browser JWT minting for scenario actors.
 *
 * Mirrors the old repo's `test/helpers.ts` makeJwt (jose HS256, same claim
 * rules as contract §2.1 / src/auth/jwt.ts). The token value is volatile and
 * is always masked to {{JWT}} by the normalizer before diffing.
 */

import { SignJWT } from "jose";

export interface JwtSpec {
  sub: string;
  /** Extra claims (admin, client_id, managed_session, …). */
  claims?: Record<string, unknown>;
  /** Unix seconds. Fixed by the runner for determinism within a run. */
  iat?: number;
  exp?: number;
}

export async function makeJwt(secret: string, spec: JwtSpec): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const { sub, claims, iat, exp } = spec;
  let builder = new SignJWT(claims ?? {}).setProtectedHeader({ alg: "HS256", typ: "JWT" }).setSubject(sub);
  builder = builder.setExpirationTime(exp ?? now + 3600);
  if (iat !== undefined) builder = builder.setIssuedAt(iat);
  return builder.sign(new TextEncoder().encode(secret));
}
