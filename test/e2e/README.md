# StackCoin E2E Tests

End-to-end tests that start a real StackCoin Phoenix server and exercise the HTTP API, WebSocket gateway, and LuckyPot game logic against it.

## Prerequisites

- Elixir/Erlang (for running StackCoin)
- Python 3.13+
- [uv](https://docs.astral.sh/uv/) (Python package manager)
- The sibling repos checked out alongside StackCoin:
  ```
  repos/
  ├── StackCoin/          # this repo
  ├── LuckyPot/           # git@github.com:…/LuckyPot.git
  └── stackcoin-python/   # git@github.com:…/stackcoin-python.git
  ```

## Setup

### 1. Create symlinks

The E2E project references `LuckyPot` and `stackcoin-python` via symlinks in `tmp/`. From the StackCoin root:

```sh
mkdir -p tmp
ln -sf ../../LuckyPot tmp/LuckyPot
ln -sf ../../stackcoin-python tmp/stackcoin-python
```

### 2. Install Python dependencies

```sh
cd test/e2e
uv sync
```

This installs `luckypot` and `stackcoin` as editable local packages (via the symlinks), plus `pytest`, `httpx`, `websockets`, and `pytest-asyncio`.

### 3. Ensure Elixir deps are compiled

From the StackCoin root:

```sh
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile
```

## Running

From the `test/e2e` directory:

```sh
uv run pytest
```

Or to run a specific test file:

```sh
uv run pytest test_stackcoin_api.py
uv run pytest test_luckypot.py
uv run pytest test_websocket_gateway.py
```

## What happens when you run `pytest`

1. A real Phoenix server starts on **port 4042** with `MIX_ENV=test` and a dedicated SQLite database (`data/e2e_test_4042.db`).
2. A seed script creates test users, a bot account, and funds them via the reserve.
3. Tests run against the live server using `httpx` (HTTP) and `websockets` (WebSocket).
4. The server is killed on teardown.

## Test files

| File | Covers |
|---|---|
| `test_stackcoin_api.py` | Transfers, requests, idempotency keys, event polling via REST |
| `test_luckypot.py` | LuckyPot game logic (enter pot, draw, instant wins, balance checks) against the real server |
| `test_websocket_gateway.py` | WebSocket connect, channel join with token auth, real-time event delivery |

## Troubleshooting

**`uv sync` fails with build errors**: Make sure the symlinks in `tmp/` exist and point to valid checkouts. Run `ls -la tmp/` to verify.

**Server fails to start**: Check that port 4042 is not already in use. The test fixture waits up to 30 seconds for the server to respond at `/api/openapi`.

**Import errors for `luckypot` or `stackcoin`**: Ensure you ran `uv sync` from the `test/e2e` directory, not the repo root. The editable installs are scoped to the local venv.
