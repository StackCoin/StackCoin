root := justfile_directory()

remote_host := "jack@jackharrhy.dev"
remote_compose_dir := "/home/jack/infra/hosts/mug"
remote_db := remote_compose_dir / "volumes/stackcoin/stackcoin.db"
local_db := "data/stackcoin.db"

python_sdk := root / "tmp/stackcoin-python"
typescript_sdk := root / "tmp/stackcoin-typescript"

app:
  iex --name stackcoin@127.0.0.1 --cookie stackcoin -S mix phx.server

livebook:
  livebook server --port 8010

test *args:
  mix test {{ args }}

cover:
  MIX_ENV=test mix coveralls.html
  @echo "Report: cover/excoveralls.html"

# Regenerate the OpenAPI spec from the Elixir codebase
generate-openapi:
  mix openapi.spec.json --spec StackCoinWeb.ApiSpec --pretty --vendor-extensions=false

# Regenerate Python SDK models from the OpenAPI spec
generate-python: generate-openapi
  cd {{ python_sdk }} && datamodel-codegen \
    --input {{ root }}/openapi.json \
    --input-file-type openapi \
    --output-model-type pydantic_v2.BaseModel \
    --output src/stackcoin/models.py \
    --target-python-version 3.13 \
    --output-datetime-class datetime
  cd {{ python_sdk }} && uvx ruff format src/
  @echo ""
  @echo "=== Python SDK changes ==="
  cd {{ python_sdk }} && git diff --stat || true

# Regenerate TypeScript SDK types from the OpenAPI spec
generate-typescript: generate-openapi
  cd {{ typescript_sdk }} && pnpm exec openapi-typescript {{ root }}/openapi.json -o src/schema.d.ts
  cd {{ typescript_sdk }} && pnpm run fmt
  @echo ""
  @echo "=== TypeScript SDK changes ==="
  cd {{ typescript_sdk }} && git diff --stat || true

# Regenerate both SDKs and show what changed
generate-sdks: generate-python generate-typescript
  @echo ""
  @echo "=== Python SDK diff ==="
  cd {{ python_sdk }} && git diff src/stackcoin/models.py || true
  @echo ""
  @echo "=== TypeScript SDK diff ==="
  cd {{ typescript_sdk }} && git diff src/schema.d.ts || true

# Keep the old name as an alias
openapi: generate-openapi

# Copy the production database to local dev.
# Stops the remote container first so SQLite checkpoints cleanly on shutdown.
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
