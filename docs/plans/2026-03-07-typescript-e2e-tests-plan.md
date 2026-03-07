# TypeScript SDK E2E Tests Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reorganize `test/e2e/` into `py/` + `ts/` subdirectories, add TypeScript E2E tests for the `stackcoin` SDK, and provide a unified runner script.

**Architecture:** Move existing Python tests into `test/e2e/py/`. Create `test/e2e/ts/` with vitest, a `global-setup.ts` that spawns a StackCoin server on port 4043, per-test DB seeding via `better-sqlite3`, and test files exercising the SDK's `Client` and `Gateway` classes. A `run-all.sh` at the `test/e2e/` root runs both suites.

**Tech Stack:** vitest, better-sqlite3, stackcoin (local), TypeScript, Node 21+

---

### Task 1: Move Python tests into `test/e2e/py/`

**Files:**
- Move: `test/e2e/conftest.py` → `test/e2e/py/conftest.py`
- Move: `test/e2e/pyproject.toml` → `test/e2e/py/pyproject.toml`
- Move: `test/e2e/uv.lock` → `test/e2e/py/uv.lock`
- Move: `test/e2e/test_stackcoin_api.py` → `test/e2e/py/test_stackcoin_api.py`
- Move: `test/e2e/test_websocket_gateway.py` → `test/e2e/py/test_websocket_gateway.py`
- Move: `test/e2e/test_luckypot.py` → `test/e2e/py/test_luckypot.py`
- Modify: `test/e2e/py/pyproject.toml` (update relative paths from `../../tmp/` to `../../../tmp/`)
- Modify: `test/e2e/py/conftest.py` (update `STACKCOIN_ROOT` from `../..` to `../../..`)
- Delete: `test/e2e/.venv/`, `test/e2e/__pycache__/`, `test/e2e/.pytest_cache/`

**Step 1: Create the `py/` directory and move files**

```bash
cd test/e2e
mkdir -p py
git mv conftest.py py/
git mv pyproject.toml py/
git mv uv.lock py/
git mv test_stackcoin_api.py py/
git mv test_websocket_gateway.py py/
git mv test_luckypot.py py/
```

Also move `.python-version` if it exists. Remove `.venv/`, `__pycache__/`, `.pytest_cache/` (they'll be regenerated).

**Step 2: Update paths in `py/pyproject.toml`**

The `[tool.uv.sources]` paths need one more `../` since we moved one level deeper:

```toml
[tool.uv.sources]
luckypot = { path = "../../../tmp/LuckyPot", editable = true }
stackcoin = { path = "../../../tmp/stackcoin-python", editable = true }
```

**Step 3: Update `STACKCOIN_ROOT` in `py/conftest.py`**

Line 26 currently reads:
```python
STACKCOIN_ROOT = os.path.join(os.path.dirname(__file__), "../..")
```

Change to:
```python
STACKCOIN_ROOT = os.path.join(os.path.dirname(__file__), "../../..")
```

**Step 4: Verify Python tests still work**

```bash
cd test/e2e/py
rm -rf .venv
uv sync
uv run pytest --co  # --co = collect-only, verifies tests are found without running
```

Expected: All tests collected (no import errors). Note: don't actually run the full suite (it takes time to start the server), just verify collection.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: move Python E2E tests into test/e2e/py/"
```

---

### Task 2: TypeScript test scaffolding — package.json, tsconfig, vitest config

**Files:**
- Create: `test/e2e/ts/package.json`
- Create: `test/e2e/ts/tsconfig.json`
- Create: `test/e2e/ts/vitest.config.ts`
- Create: `test/e2e/ts/.gitignore`

**Step 1: Create `test/e2e/ts/package.json`**

```json
{
  "name": "stackcoin-e2e-tests-ts",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "vitest run"
  },
  "dependencies": {
    "stackcoin": "file:../../../tmp/stackcoin-typescript",
    "better-sqlite3": "^11.0.0"
  },
  "devDependencies": {
    "@types/better-sqlite3": "^7.0.0",
    "vitest": "^3.0.0",
    "typescript": "^5.7.0"
  }
}
```

**Step 2: Create `test/e2e/ts/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "dist",
    "rootDir": ".",
    "lib": ["ES2022"],
    "types": ["node"]
  },
  "include": ["*.ts"]
}
```

**Step 3: Create `test/e2e/ts/vitest.config.ts`**

```typescript
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globalSetup: "./global-setup.ts",
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
```

**Step 4: Create `test/e2e/ts/.gitignore`**

```
node_modules/
dist/
```

**Step 5: Install dependencies**

```bash
cd test/e2e/ts
pnpm install
```

**Step 6: Commit**

```bash
git add test/e2e/ts/
git commit -m "feat: scaffold TypeScript E2E test project"
```

---

### Task 3: Global setup — server lifecycle

**Files:**
- Create: `test/e2e/ts/global-setup.ts`

**Context:** This file mirrors `py/conftest.py`'s `stackcoin_server` fixture. It starts the Elixir server on port 4043 before any tests and kills it after. Vitest calls `setup()` once at the start and `teardown()` once at the end.

**Step 1: Create `test/e2e/ts/global-setup.ts`**

```typescript
import { execSync, spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

const PORT = 4043;
const STACKCOIN_ROOT = resolve(import.meta.dirname, "../../..");
const DB_FILE = `./data/e2e_test_${PORT}.db`;

let serverProcess: ChildProcess | null = null;

function mixEnv(): Record<string, string> {
  return {
    ...process.env,
    MIX_ENV: "test",
    STACKCOIN_DATABASE: DB_FILE,
    PORT: String(PORT),
    SECRET_KEY_BASE:
      "test_secret_key_base_that_is_at_least_64_bytes_long_for_phoenix_to_accept_it_OK",
    PHX_SERVER: "true",
  };
}

async function waitForServer(baseUrl: string, maxWaitMs = 30_000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    try {
      const resp = await fetch(`${baseUrl}/api/openapi`);
      if (resp.ok) return;
    } catch {
      // Server not ready yet
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`Server did not start within ${maxWaitMs}ms`);
}

export async function setup(): Promise<void> {
  // Create fresh database
  const opts = { env: mixEnv(), cwd: STACKCOIN_ROOT, stdio: "pipe" as const };

  execSync("mix ecto.drop --quiet", opts);
  execSync("mix ecto.create --quiet", opts);
  execSync("mix ecto.migrate --quiet", opts);

  // Start server
  serverProcess = spawn("mix", ["phx.server"], {
    env: mixEnv(),
    cwd: STACKCOIN_ROOT,
    stdio: "pipe",
    detached: true,
  });

  await waitForServer(`http://localhost:${PORT}`);

  // Store base URL for tests to use
  process.env.__STACKCOIN_E2E_BASE_URL = `http://localhost:${PORT}`;
  process.env.__STACKCOIN_E2E_PORT = String(PORT);
}

export async function teardown(): Promise<void> {
  if (serverProcess?.pid) {
    try {
      // Kill the process group (negative PID)
      process.kill(-serverProcess.pid, "SIGTERM");
    } catch {
      // Already dead
    }

    // Wait up to 10s, then SIGKILL
    await new Promise<void>((resolve) => {
      const timeout = setTimeout(() => {
        try {
          process.kill(-serverProcess!.pid!, "SIGKILL");
        } catch {
          // Already dead
        }
        resolve();
      }, 10_000);

      serverProcess!.on("exit", () => {
        clearTimeout(timeout);
        resolve();
      });
    });
  }
}
```

**Step 2: Commit**

```bash
git add test/e2e/ts/global-setup.ts
git commit -m "feat: add vitest global setup for StackCoin server lifecycle"
```

---

### Task 4: Test helpers — DB seeding + test context

**Files:**
- Create: `test/e2e/ts/helpers.ts`

**Context:** This provides `seedDatabase()` which truncates all tables via `better-sqlite3` and runs the Elixir seed script. It returns a `TestContext` with all IDs and tokens. Called in `beforeEach()` by test files.

The Elixir seed script is identical to the one in `py/conftest.py` (the `SEED_SCRIPT` constant). The table truncation order is identical too.

**Step 1: Create `test/e2e/ts/helpers.ts`**

```typescript
import { execSync } from "node:child_process";
import { resolve } from "node:path";
import Database from "better-sqlite3";

const STACKCOIN_ROOT = resolve(import.meta.dirname, "../../..");

const ALL_TABLES = [
  "events",
  "idempotency_keys",
  "request",
  "pump",
  "transaction",
  "bot_user",
  "discord_guild",
  "discord_user",
  "internal_user",
  "user",
];

const SEED_SCRIPT = `
{:ok, owner} = StackCoin.Core.User.create_user_account("100", "E2EOwner", balance: 0)
{:ok, bot} = StackCoin.Core.Bot.create_bot_user("100", "E2ETestBot")
StackCoin.Repo.query!("INSERT INTO user (id, inserted_at, updated_at, username, balance, last_given_dole, admin, banned) VALUES (1, datetime('now'), datetime('now'), 'StackCoin Reserve System', 0, null, 0, 0)")
StackCoin.Repo.query!("INSERT INTO internal_user (id, identifier) VALUES (1, 'StackCoin Reserve System')")
{:ok, _pump} = StackCoin.Core.Reserve.pump_reserve(owner.id, 5000, "E2E funding")
{:ok, _txn} = StackCoin.Core.Bank.transfer_between_users(1, bot.user.id, 1000, "E2E bot funding")
{:ok, user1} = StackCoin.Core.User.create_user_account("200", "TestUser1", balance: 0)
{:ok, _txn} = StackCoin.Core.Bank.transfer_between_users(1, user1.id, 500, "User1 funding")
{:ok, user2} = StackCoin.Core.User.create_user_account("300", "TestUser2", balance: 0)
{:ok, _txn} = StackCoin.Core.Bank.transfer_between_users(1, user2.id, 500, "User2 funding")
IO.puts("BOT_TOKEN:" <> bot.token)
IO.puts("BOT_USER_ID:" <> Integer.to_string(bot.user.id))
IO.puts("USER1_ID:" <> Integer.to_string(user1.id))
IO.puts("USER1_DISCORD_ID:200")
IO.puts("USER2_ID:" <> Integer.to_string(user2.id))
IO.puts("USER2_DISCORD_ID:300")
`;

export interface TestContext {
  baseUrl: string;
  botToken: string;
  botUserId: number;
  user1Id: number;
  user1DiscordId: string;
  user2Id: number;
  user2DiscordId: string;
}

function truncateAllTables(port: number): void {
  const dbPath = resolve(STACKCOIN_ROOT, `data/e2e_test_${port}.db`);
  const db = new Database(dbPath, { timeout: 10_000 });
  try {
    db.pragma("busy_timeout = 5000");
    db.pragma("foreign_keys = OFF");
    for (const table of ALL_TABLES) {
      db.exec(`DELETE FROM "${table}"`);
    }
    db.exec("DELETE FROM sqlite_sequence");
    db.pragma("foreign_keys = ON");
  } finally {
    db.close();
  }
}

function runSeed(port: number): Record<string, string> {
  const result = execSync(`mix run -e '${SEED_SCRIPT.replace(/'/g, "'\\''")}'`, {
    env: {
      ...process.env,
      MIX_ENV: "test",
      PHX_SERVER: "true",
      STACKCOIN_DATABASE: `./data/e2e_test_${port}.db`,
    },
    cwd: STACKCOIN_ROOT,
    encoding: "utf-8",
    timeout: 30_000,
  });

  const values: Record<string, string> = {};
  for (const line of result.trim().split("\n")) {
    const colonIdx = line.indexOf(":");
    if (colonIdx > 0) {
      const key = line.slice(0, colonIdx).trim();
      const val = line.slice(colonIdx + 1).trim();
      if (
        ["BOT_TOKEN", "BOT_USER_ID", "USER1_ID", "USER1_DISCORD_ID", "USER2_ID", "USER2_DISCORD_ID"].includes(key)
      ) {
        values[key] = val;
      }
    }
  }

  for (const k of ["BOT_TOKEN", "BOT_USER_ID", "USER1_ID", "USER2_ID"]) {
    if (!(k in values)) {
      throw new Error(`Seed script did not output ${k}. Got: ${JSON.stringify(values)}`);
    }
  }

  return values;
}

export function seedDatabase(): TestContext {
  const port = Number(process.env.__STACKCOIN_E2E_PORT ?? "4043");
  const baseUrl = process.env.__STACKCOIN_E2E_BASE_URL ?? `http://localhost:${port}`;

  truncateAllTables(port);
  const seed = runSeed(port);

  return {
    baseUrl,
    botToken: seed.BOT_TOKEN,
    botUserId: Number(seed.BOT_USER_ID),
    user1Id: Number(seed.USER1_ID),
    user1DiscordId: seed.USER1_DISCORD_ID ?? "200",
    user2Id: Number(seed.USER2_ID),
    user2DiscordId: seed.USER2_DISCORD_ID ?? "300",
  };
}
```

**Important:** The seed script order matters -- the reserve user (ID 1) must be created via raw SQL before `pump_reserve` is called. Check the Python conftest.py's `SEED_SCRIPT` carefully and replicate the exact order.

**Step 2: Commit**

```bash
git add test/e2e/ts/helpers.ts
git commit -m "feat: add test helpers for DB seeding and test context"
```

---

### Task 5: REST client tests

**Files:**
- Create: `test/e2e/ts/stackcoin-client.test.ts`

**Context:** These tests import `Client` and `StackCoinError` from the `stackcoin` package (which resolves to `../../../tmp/stackcoin-typescript` via the local file dep). Each test calls `seedDatabase()` in `beforeEach` for isolation.

**Step 1: Create `test/e2e/ts/stackcoin-client.test.ts`**

```typescript
import { describe, it, expect, beforeEach } from "vitest";
import { Client, StackCoinError } from "stackcoin";
import { seedDatabase, type TestContext } from "./helpers.js";

let ctx: TestContext;
let client: Client;

beforeEach(() => {
  ctx = seedDatabase();
  client = new Client({ token: ctx.botToken, baseUrl: ctx.baseUrl });
});

describe("auth", () => {
  it("rejects invalid token with 401", async () => {
    const badClient = new Client({ token: "totally_fake_token", baseUrl: ctx.baseUrl });
    await expect(badClient.getMe()).rejects.toThrow(StackCoinError);
    try {
      await badClient.getMe();
    } catch (e) {
      expect(e).toBeInstanceOf(StackCoinError);
      expect((e as StackCoinError).statusCode).toBe(401);
    }
  });
});

describe("read endpoints", () => {
  it("getMe returns the bot user", async () => {
    const me = await client.getMe();
    expect(me.id).toBe(ctx.botUserId);
    expect(me.username).toBeDefined();
    expect(me.balance).toBeGreaterThan(0);
  });

  it("getUser returns another user", async () => {
    const user = await client.getUser(ctx.user1Id);
    expect(user.id).toBe(ctx.user1Id);
    expect(user.username).toBeDefined();
  });

  it("getUsers returns a list", async () => {
    const users = await client.getUsers();
    expect(users.length).toBeGreaterThan(0);
  });

  it("getTransactions returns seeded transactions", async () => {
    const txns = await client.getTransactions();
    expect(txns.length).toBeGreaterThan(0);
    expect(txns[0].id).toBeDefined();
    expect(txns[0].amount).toBeDefined();
  });

  it("getTransaction returns a single transaction", async () => {
    const txns = await client.getTransactions();
    const txn = await client.getTransaction(txns[0].id);
    expect(txn.id).toBe(txns[0].id);
  });
});

describe("transfers", () => {
  it("send succeeds and updates balances", async () => {
    const result = await client.send(ctx.user1Id, 5, { label: "e2e test" });
    expect(result.success).toBe(true);
    expect(result.amount).toBe(5);
    expect(result.transaction_id).toBeDefined();
  });

  it("send with insufficient balance throws", async () => {
    await expect(client.send(ctx.user1Id, 999999)).rejects.toThrow(StackCoinError);
    try {
      await client.send(ctx.user1Id, 999999);
    } catch (e) {
      expect((e as StackCoinError).statusCode).toBe(422);
    }
  });

  it("self-transfer throws", async () => {
    await expect(client.send(ctx.botUserId, 1)).rejects.toThrow(StackCoinError);
    try {
      await client.send(ctx.botUserId, 1);
    } catch (e) {
      expect((e as StackCoinError).statusCode).toBe(400);
    }
  });
});

describe("requests", () => {
  it("create and deny request lifecycle", async () => {
    const created = await client.createRequest(ctx.user1Id, 10, { label: "e2e request" });
    expect(created.request_id).toBeDefined();
    expect(created.status).toBe("pending");

    const denied = await client.denyRequest(created.request_id);
    expect(denied.success).toBe(true);
    expect(denied.status).toBe("denied");
  });

  it("acceptRequest rejects for requester", async () => {
    const created = await client.createRequest(ctx.user1Id, 1);
    await expect(client.acceptRequest(created.request_id)).rejects.toThrow(StackCoinError);
    try {
      await client.acceptRequest(created.request_id);
    } catch (e) {
      expect((e as StackCoinError).statusCode).toBe(403);
    }
  });

  it("getRequest returns a single request", async () => {
    const created = await client.createRequest(ctx.user1Id, 5);
    const fetched = await client.getRequest(created.request_id);
    expect(fetched.id).toBe(created.request_id);
  });

  it("getRequests returns list", async () => {
    await client.createRequest(ctx.user1Id, 5);
    const requests = await client.getRequests();
    expect(requests.length).toBeGreaterThan(0);
  });
});

describe("events", () => {
  it("getEvents returns events after transfer", async () => {
    await client.send(ctx.user1Id, 1, { label: "event test" });
    const events = await client.getEvents();
    expect(events.length).toBeGreaterThan(0);
    const transfers = events.filter((e) => e.type === "transfer.completed");
    expect(transfers.length).toBeGreaterThan(0);
  });
});

describe("idempotency", () => {
  it("same idempotency key returns same result", async () => {
    const key = "e2e-idem-key-1";
    const r1 = await client.send(ctx.user1Id, 3, { idempotencyKey: key });
    const r2 = await client.send(ctx.user1Id, 3, { idempotencyKey: key });
    expect(r1.transaction_id).toBe(r2.transaction_id);

    // Balance should only decrease by 3, not 6
    const me = await client.getMe();
    expect(me.balance).toBe(1000 - 3);
  });

  it("different keys create separate transactions", async () => {
    const r1 = await client.send(ctx.user1Id, 1, { idempotencyKey: "key-a" });
    const r2 = await client.send(ctx.user1Id, 1, { idempotencyKey: "key-b" });
    expect(r1.transaction_id).not.toBe(r2.transaction_id);
  });
});

describe("discord", () => {
  it("getDiscordBotId returns a string", async () => {
    const botId = await client.getDiscordBotId();
    expect(typeof botId).toBe("string");
    expect(botId.length).toBeGreaterThan(0);
  });
});
```

**Step 2: Verify tests compile**

```bash
cd test/e2e/ts
npx tsc --noEmit
```

Note: Tests won't actually pass yet until the server is running, but they should compile.

**Step 3: Commit**

```bash
git add test/e2e/ts/stackcoin-client.test.ts
git commit -m "feat: add REST client E2E tests"
```

---

### Task 6: Gateway tests

**Files:**
- Create: `test/e2e/ts/stackcoin-gateway.test.ts`

**Context:** These tests exercise the `Gateway` class. Gateway tests are trickier because they involve async event delivery. The pattern: create gateway, register handler that resolves a Promise, trigger an action via the client, await the promise with a timeout.

**Step 1: Create `test/e2e/ts/stackcoin-gateway.test.ts`**

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { Client, Gateway } from "stackcoin";
import type { AnyEvent, TransferCompletedEvent } from "stackcoin";
import { seedDatabase, type TestContext } from "./helpers.js";

let ctx: TestContext;
let client: Client;
let gateway: Gateway | null = null;

beforeEach(() => {
  ctx = seedDatabase();
  client = new Client({ token: ctx.botToken, baseUrl: ctx.baseUrl });
});

afterEach(() => {
  if (gateway) {
    gateway.stop();
    gateway = null;
  }
});

function wsUrl(baseUrl: string): string {
  return baseUrl.replace("http://", "ws://") + "/ws";
}

/**
 * Helper: create a gateway, connect in background, and wait for handler to fire.
 * Returns a promise that resolves with the received event.
 */
function waitForEvent(
  gw: Gateway,
  eventType: string,
  timeoutMs = 10_000,
): Promise<AnyEvent> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`Timed out waiting for ${eventType} event`));
    }, timeoutMs);

    gw.on(eventType, (event) => {
      clearTimeout(timeout);
      resolve(event);
    });
  });
}

describe("gateway", () => {
  it("receives transfer.completed event", async () => {
    gateway = new Gateway({
      token: ctx.botToken,
      wsUrl: wsUrl(ctx.baseUrl),
    });

    const eventPromise = waitForEvent(gateway, "transfer.completed");

    // Connect in background (don't await -- it runs forever)
    const connectPromise = gateway.connect();

    // Give the gateway a moment to connect and join
    await new Promise((r) => setTimeout(r, 1000));

    // Trigger a transfer
    await client.send(ctx.user1Id, 1, { label: "gateway test" });

    // Wait for the event
    const event = await eventPromise;
    expect(event.type).toBe("transfer.completed");
    const data = (event as TransferCompletedEvent).data;
    expect(data.amount).toBe(1);

    gateway.stop();
    // Wait for connect to finish after stop
    await connectPromise;
  });

  it("replays events with lastEventId", async () => {
    // First, create an event via REST
    await client.send(ctx.user1Id, 1, { label: "before gateway" });

    const receivedEvents: AnyEvent[] = [];

    gateway = new Gateway({
      token: ctx.botToken,
      wsUrl: wsUrl(ctx.baseUrl),
      lastEventId: 0, // Replay all events
    });

    // Collect events for a short window
    gateway.on("transfer.completed", (event) => {
      receivedEvents.push(event);
    });
    gateway.on("request.created", (event) => {
      receivedEvents.push(event);
    });
    gateway.on("request.accepted", (event) => {
      receivedEvents.push(event);
    });
    gateway.on("request.denied", (event) => {
      receivedEvents.push(event);
    });

    const connectPromise = gateway.connect();

    // Wait for replay to arrive
    await new Promise((r) => setTimeout(r, 3000));

    expect(receivedEvents.length).toBeGreaterThan(0);

    gateway.stop();
    await connectPromise;
  });

  it("tracks event IDs via onEventId callback", async () => {
    const eventIds: number[] = [];

    gateway = new Gateway({
      token: ctx.botToken,
      wsUrl: wsUrl(ctx.baseUrl),
      lastEventId: 0,
      onEventId: (id) => eventIds.push(id),
    });

    // Register a handler so events are dispatched
    gateway.on("transfer.completed", () => {});
    gateway.on("request.created", () => {});
    gateway.on("request.accepted", () => {});
    gateway.on("request.denied", () => {});

    const connectPromise = gateway.connect();

    await new Promise((r) => setTimeout(r, 3000));

    expect(eventIds.length).toBeGreaterThan(0);
    // IDs should be ascending
    for (let i = 1; i < eventIds.length; i++) {
      expect(eventIds[i]).toBeGreaterThan(eventIds[i - 1]);
    }

    gateway.stop();
    await connectPromise;
  });
});
```

**Step 2: Commit**

```bash
git add test/e2e/ts/stackcoin-gateway.test.ts
git commit -m "feat: add WebSocket gateway E2E tests"
```

---

### Task 7: Runner script and README

**Files:**
- Create: `test/e2e/run-all.sh`
- Create: `test/e2e/README.md` (replace old one)

**Step 1: Create `test/e2e/run-all.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Python E2E tests ==="
(cd py && uv run pytest "$@")

echo ""
echo "=== TypeScript E2E tests ==="
(cd ts && pnpm test)
```

```bash
chmod +x test/e2e/run-all.sh
```

**Step 2: Create `test/e2e/README.md`**

```markdown
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
```

**Step 3: Update the stackcoin-typescript README**

In `tmp/stackcoin-typescript/README.md`, replace the Testing section to reference the new location:

The Testing section currently says tests live in the main StackCoin repo at `test/e2e`. Update it to point to `test/e2e/ts`:

```markdown
## Testing

Tests for this library live in the main
[StackCoin/StackCoin](https://github.com/StackCoin/StackCoin) repository as
end-to-end tests that boot a real StackCoin server:

```sh
cd /path/to/StackCoin/test/e2e/ts
pnpm install
pnpm test
```

The E2E suite tests the `Client` and `Gateway` classes against a live server.
```

**Step 4: Commit**

```bash
git add test/e2e/run-all.sh test/e2e/README.md
git commit -m "feat: add unified runner script and updated README"
```

Then commit the stackcoin-typescript README update in its own repo.

---

### Task 8: Run the TypeScript E2E tests

**Step 1: Run the tests**

```bash
cd test/e2e/ts
pnpm test
```

Expected: All tests pass (assuming Elixir deps are compiled).

**Step 2: Fix any failures**

Common issues:
- The seed script's single-quote escaping in `execSync` may need adjustment
- The `import.meta.dirname` requires Node 21.2+ — verify it works
- The `better-sqlite3` native addon may need rebuilding
- Gateway tests may need longer timeouts or different timing

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve E2E test issues"
```
