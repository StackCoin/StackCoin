import Config

config :stackcoin,
  ecto_repos: [StackCoin.Repo]

config :stackcoin, env: Mix.env()

config :stackcoin, StackCoinWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [html: StackCoinWeb.ErrorHTML, json: StackCoinWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: StackCoin.PubSub,
  live_view: [signing_salt: "chHXSNvT"]

config :esbuild,
  version: "0.17.11",
  stackcoin: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  stackcoin: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
