import Config

config :stackcoin, StackCoin.Repo,
  database: "./data/test.db",
  pool: Ecto.Adapters.SQL.Sandbox
