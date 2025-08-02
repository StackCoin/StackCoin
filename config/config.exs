import Config

config :stackcoin,
  ecto_repos: [StackCoin.Repo]

config :stackcoin, env: Mix.env()
