app:
  iex --name stackcoin@127.0.0.1 --cookie stackcoin -S mix phx.server

livebook:
  livebook server --port 8010

openapi:
  mix openapi.spec.json --spec StackCoinWeb.ApiSpec
  mv openapi.json temp.json
  cat temp.json | jq > openapi.json
  rm temp.json
