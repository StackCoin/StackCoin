import Config
import Dotenvy

source!([".env", System.get_env()])

# In test env, test.exs already sets the database path (./data/test.db).
# Only apply the runtime default for non-test environments, or when
# STACKCOIN_DATABASE is explicitly set (e.g. E2E tests).
if config_env() != :test or System.get_env("STACKCOIN_DATABASE") do
  config :stackcoin, StackCoin.Repo,
    database: env!("STACKCOIN_DATABASE", :string, "./data/stackcoin.db")
end

config :stackcoin,
  test_guild_id: env!("STACKCOIN_TEST_GUILD_ID", :integer, nil),
  admin_user_id: env!("STACKCOIN_ADMIN_USER_ID", :string, nil)

config :stackcoin,
  discord_application_id: env!("STACKCOIN_DISCORD_APPLICATION_ID", :integer, nil),
  discord_token: env!("STACKCOIN_DISCORD_TOKEN", :string, nil)

# Dashboard basic auth — no password in dev means no auth prompt.
# In prod, set DASHBOARD_USER and DASHBOARD_PASSWORD env vars.
if password = System.get_env("DASHBOARD_PASSWORD") do
  config :stackcoin,
    dashboard_username: System.get_env("DASHBOARD_USER", "admin"),
    dashboard_password: password
end

if System.get_env("PHX_SERVER") do
  config :stackcoin, StackCoinWeb.Endpoint, server: true
end

# Allow PORT env var to override the HTTP port in any environment.
if port = System.get_env("PORT") do
  config :stackcoin, StackCoinWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
end

# When running a real HTTP server in test mode (E2E tests), disable the
# Ecto sandbox pool so the server can handle requests from external clients.
if config_env() == :test and System.get_env("PHX_SERVER") do
  config :stackcoin, StackCoin.Repo, pool: DBConnection.ConnectionPool, pool_size: 5
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "stackcoin.world"
  port = String.to_integer(System.get_env("PORT") || "80")

  config :stackcoin, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :stackcoin, StackCoinWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
