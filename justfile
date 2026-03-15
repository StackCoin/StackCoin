remote_host := "jack@jackharrhy.dev"
remote_compose_dir := "/home/jack/infra/hosts/mug"
remote_db := remote_compose_dir / "volumes/stackcoin/stackcoin.db"
local_db := "data/stackcoin.db"

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

# Copy the production database to local dev
pull-db:
  @echo "Stopping stackcoin container on remote..."
  ssh {{ remote_host }} "cd {{ remote_compose_dir }} && docker compose stop stackcoin"
  @echo "Copying database..."
  scp {{ remote_host }}:{{ remote_db }} {{ local_db }}
  @echo "Starting stackcoin container on remote..."
  ssh {{ remote_host }} "cd {{ remote_compose_dir }} && docker compose start stackcoin"
  @echo "Running any pending migrations on local copy..."
  mix ecto.migrate
  @echo "Done. Production database copied to {{ local_db }}"
