import Config

config :stackcoin, StackCoinWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "gVKt+3BaJ3VSWTOg5NnagffKGETEHJFK4VRy4WcwJXVOvAG0loVoyQMjwUeYXqlP",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:stackcoin, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:stackcoin, ~w(--watch)]}
  ]

config :stackcoin, StackCoinWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/stackcoin_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :stackcoin, dev_routes: true

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true
