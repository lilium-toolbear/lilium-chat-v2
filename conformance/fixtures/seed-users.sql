-- Conformance profile fixtures (shared dev PG instance).
--
-- Both targets resolve sender profiles from `public.users`:
--   * old Worker: Hyperdrive LILIUM_DB → src/profile/resolve.ts
--     (`SELECT user_id::text, full_name, avatar_url FROM users ...`)
--   * new Elixir: same table on the same instance (spec §4 / D16)
-- Seeding identical rows keeps profile display deterministic across targets.

CREATE TABLE IF NOT EXISTS public.users (
  user_id    UUID PRIMARY KEY,
  full_name  TEXT,
  avatar_url TEXT
);

INSERT INTO public.users (user_id, full_name, avatar_url) VALUES
  ('6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f', 'Conformance Alice', NULL)
ON CONFLICT (user_id) DO UPDATE SET full_name = EXCLUDED.full_name, avatar_url = EXCLUDED.avatar_url;
