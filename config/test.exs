import Config

config :stackcoin, StackCoin.Repo,
  database: "./data/test.db",
  pool: Ecto.Adapters.SQL.Sandbox

config :stackcoin, StackCoinWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Zjmqe6E4mqa+TD9pMwgyRM1kzC7uR9s/QelqY6fIk7WLRwjypYTCK9TrQnVdAuJd",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true
