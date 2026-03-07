app:
  iex --name stackcoin@127.0.0.1 --cookie stackcoin -S mix phx.server

livebook:
  livebook server --port 8010

openapi:
  mix openapi.spec.json --spec StackCoinWeb.ApiSpec --pretty --vendor-extensions=false

test *args:
  mix test {{ args }}

cover:
  MIX_ENV=test mix coveralls.html
  @echo "Report: cover/excoveralls.html"
