-- Conformance profile fixtures (shared dev PG instance).
--
-- Both targets resolve sender profiles from `public.users`:
--   * old Worker: Hyperdrive LILIUM_DB → src/profile/resolve.ts
--     (`SELECT user_id::text, full_name, avatar_url FROM users
--      WHERE user_id = ANY($1::uuid[])`)
--   * new Elixir: same table on the same instance (spec §4 / D16)
-- Seeding identical rows keeps profile display deterministic across targets.
--
-- Column type must be UUID: the old Worker's query casts the parameter to
-- `uuid[]` (the production ToolBear users table is UUID-keyed). A VARCHAR
-- column makes `varchar = ANY(uuid[])` a type error the Worker swallows —
-- it then falls back to `user-<first8>` for every profile while the Elixir
-- side resolves real names, so NO profile field can ever converge. The
-- self-heal below converts a legacy VARCHAR table idempotently (both local
-- DBs were bootstrapped VARCHAR by the early dev migration; fresh DBs get
-- UUID from CREATE TABLE).

CREATE TABLE IF NOT EXISTS public.users (
  user_id    UUID PRIMARY KEY,
  full_name  TEXT,
  avatar_url TEXT
);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'users'
      AND column_name = 'user_id'
      AND data_type <> 'uuid'
  ) THEN
    ALTER TABLE public.users
      ALTER COLUMN user_id TYPE uuid USING user_id::uuid;
  END IF;
END
$$;

INSERT INTO public.users (user_id, full_name, avatar_url) VALUES
  ('6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f', 'Conformance Alice', NULL),
  ('6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e70', 'Conformance Bob', NULL),
  ('6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e80', 'Conformance Carol', NULL)
ON CONFLICT (user_id) DO UPDATE SET full_name = EXCLUDED.full_name, avatar_url = EXCLUDED.avatar_url;
