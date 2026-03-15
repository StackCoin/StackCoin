ExUnit.start()

# Clean stale data that may have been committed outside the Ecto sandbox
# (e.g. manual iex sessions, PHX_SERVER=true runs against test.db).
# Only truncate tables that don't contain migration-seeded data.
# The reserve user (ID 1) in `user` and `internal_user` must be preserved.
for table <-
      ~w(events idempotency_keys request pump transaction bot_user discord_guild discord_user) do
  StackCoin.Repo.query!("DELETE FROM \"#{table}\"")
end

Ecto.Adapters.SQL.Sandbox.mode(StackCoin.Repo, :manual)
