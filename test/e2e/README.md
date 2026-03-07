# StackCoin E2E Tests

End-to-end tests that start a real StackCoin Phoenix server and exercise the HTTP API, WebSocket gateway, SDK clients, and LuckyPot game logic against it.

## Prerequisites

- Elixir/Erlang (for running StackCoin)
- Python 3.13+ with [uv](https://docs.astral.sh/uv/)
- Node 21+ with [pnpm](https://pnpm.io/)
- The sibling repos checked out alongside StackCoin:
  ```
  repos/
  ├── StackCoin/              # this repo
  ├── LuckyPot/               # git@github.com:…/LuckyPot.git
  ├── stackcoin-python/       # git@github.com:…/stackcoin-python.git
  └── stackcoin-typescript/   # git@github.com:…/stackcoin-typescript.git
  ```

## Setup

### 1. Create symlinks

From the StackCoin root:

```sh
mkdir -p tmp
ln -sf ../../LuckyPot tmp/LuckyPot
ln -sf ../../stackcoin-python tmp/stackcoin-python
ln -sf ../../stackcoin-typescript tmp/stackcoin-typescript
```

### 2. Install dependencies

```sh
# Python
cd test/e2e/py && uv sync

# TypeScript
cd test/e2e/ts && pnpm install
```

### 3. Ensure Elixir deps are compiled

From the StackCoin root:

```sh
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile
```

## Running

### Run everything

From the `test/e2e` directory:

```sh
./run-all.sh
```

### Run suites individually

```sh
# Python tests (port 4042)
cd test/e2e/py
uv run pytest

# TypeScript tests (port 4043)
cd test/e2e/ts
pnpm test
```

## Structure

```
test/e2e/
├── run-all.sh                     # Runs both suites
├── py/                            # Python tests (pytest)
│   ├── conftest.py                # Server lifecycle + DB seeding (port 4042)
│   ├── test_stackcoin_api.py      # REST API tests (raw httpx)
│   ├── test_websocket_gateway.py  # WebSocket protocol tests (raw websockets)
│   └── test_luckypot.py           # LuckyPot game logic tests
└── ts/                            # TypeScript tests (vitest)
    ├── global-setup.ts            # Server lifecycle (port 4043)
    ├── helpers.ts                 # DB seeding + test context
    ├── stackcoin-client.test.ts   # stackcoin SDK Client tests
    └── stackcoin-gateway.test.ts  # stackcoin SDK Gateway tests
```

The Python suite tests the raw API surface (HTTP + WebSocket protocol) and LuckyPot integration. The TypeScript suite tests the `stackcoin` npm package (Client and Gateway classes). Each suite starts its own server on a separate port.
