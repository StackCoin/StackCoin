import Config
import Dotenvy

source!([".env", System.get_env()])

config :stackcoin, StackCoin.Repo, database: env!("STACKCOIN_DATABASE", :string, "./data/stackcoin.db")

config :nostrum,
  token: env!("STACKCOIN_DISCORD_TOKEN", :string, nil)
