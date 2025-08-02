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
  token: env!("STACKCOIN_DISCORD_TOKEN", :string, nil)
