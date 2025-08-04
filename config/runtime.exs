import Config
import Dotenvy

source!([".env", System.get_env()])

config :stackcoin, StackCoin.Repo,
  database: env!("STACKCOIN_DATABASE", :string, "./data/stackcoin.db")

config :stackcoin,
  test_guild_id: env!("STACKCOIN_TEST_GUILD_ID", :integer, nil),
  admin_user_id: env!("STACKCOIN_ADMIN_USER_ID", :string, nil)

config :nostrum,
  id: env!("STACKCOIN_DISCORD_APPLICATION_ID", :integer, nil),
  token: env!("STACKCOIN_DISCORD_TOKEN", :string, nil),
  ffmpeg: nil,
  youtube_dl: nil,
  streamlink: nil

if System.get_env("PHX_SERVER") do
  config :stackcoin, StackCoinWeb.Endpoint, server: true
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
