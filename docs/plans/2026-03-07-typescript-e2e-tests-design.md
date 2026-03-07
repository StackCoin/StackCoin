# TypeScript SDK E2E Tests Design

## Overview

Add E2E tests for the `stackcoin` TypeScript SDK that exercise the `Client` and `Gateway` classes against a real StackCoin server. Reorganize `test/e2e/` into `py/` and `ts/` subdirectories with a shared runner script.

## Directory Reorganization

```
test/e2e/
├── run-all.sh              # Runs both suites sequentially
├── README.md               # Documents both suites
├── py/                     # Existing Python tests (moved from e2e root)
│   ├── conftest.py
│   ├── pyproject.toml      # Paths updated for new depth
│   ├── uv.lock
│   ├── .python-version
│   ├── test_stackcoin_api.py
│   ├── test_websocket_gateway.py
│   └── test_luckypot.py
└── ts/                     # New TypeScript SDK tests
    ├── package.json
    ├── tsconfig.json
    ├── vitest.config.ts
    ├── global-setup.ts     # Server lifecycle (port 4043)
    ├── helpers.ts           # DB seeding + test context
    ├── stackcoin-client.test.ts
    └── stackcoin-gateway.test.ts
```

## Server Lifecycle (global-setup.ts)

Mirrors `conftest.py` exactly but on port 4043:

1. Run `mix ecto.drop`, `mix ecto.create`, `mix ecto.migrate` with `MIX_ENV=test`, `STACKCOIN_DATABASE=./data/e2e_test_4043.db`, `PHX_SERVER=true`
2. Spawn `mix phx.server` with `PORT=4043`
3. Poll `GET http://localhost:4043/api/openapi` every 1s for up to 30s
4. Teardown: kill process group with SIGTERM, then SIGKILL after 10s

## Per-test Seeding (helpers.ts)

Uses `better-sqlite3` to truncate tables in dependency-safe order (same as Python):
`events, idempotency_keys, request, pump, transaction, bot_user, discord_guild, discord_user, internal_user, user`

Then runs the same Elixir seed script via `child_process.execSync`, parses stdout for `BOT_TOKEN`, `BOT_USER_ID`, `USER1_ID`, `USER2_ID`, and returns a typed `TestContext`.

## Test Coverage

### stackcoin-client.test.ts

Exercises the SDK `Client` class:

- **Auth errors:** bogus token -> `getMe()` throws `StackCoinError` with statusCode 401
- **Read endpoints:** `getMe()` returns bot user, `getUser()` returns other user, `getUsers()` returns list, `getTransactions()` returns list with seeded transactions, `getTransaction()` returns single
- **Transfers:** `send()` success + balance changes, insufficient balance throws (422), self-transfer throws (400)
- **Requests:** `createRequest()` + `denyRequest()` lifecycle, `acceptRequest()` rejects for requester (403), `getRequest()` + `getRequests()`
- **Events:** `getEvents()` returns events after transfer, auto-pagination works
- **Idempotency:** `send()` with same `idempotencyKey` returns identical result, different keys create separate transactions
- **Discord:** `getDiscordBotId()` returns string, `getDiscordGuilds()` returns list
- **Error shape:** `StackCoinError` has `statusCode`, `error`, `message`

### stackcoin-gateway.test.ts

Exercises the SDK `Gateway` class:

- **Connect and receive:** register handler with `.on()`, make transfer via client, handler fires with correct event type
- **Event replay:** connect with `lastEventId: 0`, verify replayed events arrive through handler
- **Cursor tracking:** `onEventId` callback fires with ascending event IDs
- **Stop:** `gateway.stop()` terminates cleanly

## Dependencies (ts/package.json)

- `vitest` -- test runner
- `better-sqlite3` + `@types/better-sqlite3` -- DB truncation
- `stackcoin` -- local path to `../../../tmp/stackcoin-typescript`

## Run Script (run-all.sh)

Runs Python suite first, then TypeScript. Both manage their own server on separate ports (4042 / 4043).

## Decisions

- **Separate ports (4042 / 4043):** Allows running both suites independently or in parallel without conflicts.
- **`better-sqlite3` over raw child_process:** Direct SQLite access is faster and more reliable for table truncation than shelling out.
- **vitest over jest:** Modern, fast, ESM-native, works with TypeScript out of the box.
- **Replicate server lifecycle rather than share it:** Each suite is self-contained. No cross-language coordination needed.
