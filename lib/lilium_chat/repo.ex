defmodule LiliumChat.Repo do
  @moduledoc """
  PostgreSQL repo for the lilium-chat v2 backend.

  ## Schemas (spec §3, §4)

  * `chat_v2` — **default prefix**. All business tables
    (channels, channel_members, messages, events, attachments, …).
  * `public.users` — ToolBear profiles. Same PG instance, different
    schema. Query it on this same Repo with an explicit
    `prefix: "public"` option (e.g. `Repo.all(User, prefix: "public")`
    or `Ecto.Query` with `from u in User, prefix: ^"public"`) — reads
    must stay on one instance / bounded query count (spec §4).
  """
  use Ecto.Repo,
    otp_app: :lilium_chat,
    adapter: Ecto.Adapters.Postgres,
    prefix: "chat_v2"
end
