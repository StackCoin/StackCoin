# StackCoin TypeScript SDK Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a TypeScript client library for the StackCoin API with REST client, WebSocket gateway, and npm-publishable package structure.

**Architecture:** `openapi-typescript` generates types from `openapi.json`. A `Client` class wraps `openapi-fetch` for type-safe HTTP. A `Gateway` class implements the Phoenix Channel WebSocket protocol using native `WebSocket`. Everything is ESM-only, built with `tsup`, managed with `pnpm`.

**Tech Stack:** TypeScript, openapi-typescript, openapi-fetch, tsup, pnpm, native WebSocket

**Working directory:** `tmp/stackcoin-typescript/` (already has `.git/` initialized)

---

### Task 1: Project scaffolding — package.json, tsconfig, tsup, justfile

**Files:**
- Create: `tmp/stackcoin-typescript/package.json`
- Create: `tmp/stackcoin-typescript/tsconfig.json`
- Create: `tmp/stackcoin-typescript/tsup.config.ts`
- Create: `tmp/stackcoin-typescript/justfile`
- Create: `tmp/stackcoin-typescript/.gitignore`

**Step 1: Create package.json**

```json
{
  "name": "stackcoin",
  "version": "0.1.0",
  "description": "TypeScript library for the StackCoin API",
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.js",
      "types": "./dist/index.d.ts"
    }
  },
  "files": ["dist"],
  "engines": {
    "node": ">=21.0.0"
  },
  "scripts": {
    "build": "tsup",
    "generate": "openapi-typescript ../../openapi.json -o src/schema.d.ts",
    "typecheck": "tsc --noEmit",
    "prepublishOnly": "pnpm run build"
  },
  "license": "MIT",
  "dependencies": {
    "openapi-fetch": "^0.13.0"
  },
  "devDependencies": {
    "openapi-typescript": "^7.0.0",
    "tsup": "^8.0.0",
    "typescript": "^5.7.0"
  }
}
```

**Step 2: Create tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "dist",
    "rootDir": "src",
    "lib": ["ES2022"]
  },
  "include": ["src"]
}
```

**Step 3: Create tsup.config.ts**

```typescript
import { defineConfig } from "tsup";

export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm"],
  dts: true,
  clean: true,
  target: "es2022",
});
```

**Step 4: Create justfile**

```just
stackcoin_root := env("STACKCOIN_ROOT", "../..")

generate:
  pnpm run generate
```

**Step 5: Create .gitignore**

```
node_modules/
dist/
```

**Step 6: Install dependencies**

Run: `pnpm install` (in `tmp/stackcoin-typescript/`)
Expected: lockfile created, node_modules populated

**Step 7: Commit**

```bash
git add -A
git commit -m "feat: project scaffolding with pnpm, tsup, openapi-typescript"
```

---

### Task 2: Generate types from openapi.json

**Files:**
- Generate: `tmp/stackcoin-typescript/src/schema.d.ts`

**Step 1: Run type generation**

Run: `pnpm run generate` (in `tmp/stackcoin-typescript/`)
Expected: `src/schema.d.ts` created with TypeScript interfaces for all OpenAPI schemas and paths.

**Step 2: Verify generated types contain key interfaces**

Scan `src/schema.d.ts` for:
- `paths` object with `/api/user/me`, `/api/users`, `/api/events` etc.
- `components.schemas` with `User`, `Transaction`, `Request`, `Event` etc.
- Discriminated union for events via `oneOf`

**Step 3: Commit**

```bash
git add src/schema.d.ts
git commit -m "feat: generate TypeScript types from openapi.json"
```

---

### Task 3: Error classes

**Files:**
- Create: `tmp/stackcoin-typescript/src/errors.ts`

**Step 1: Implement error classes**

```typescript
export class StackCoinError extends Error {
  public readonly statusCode: number;
  public readonly error: string;

  constructor(statusCode: number, error: string, message?: string) {
    super(`${statusCode} ${error}${message ? `: ${message}` : ""}`);
    this.name = "StackCoinError";
    this.statusCode = statusCode;
    this.error = error;
  }
}

export class TooManyMissedEventsError extends StackCoinError {
  public readonly missedCount: number;
  public readonly replayLimit: number;

  constructor(missedCount: number, replayLimit: number, message: string) {
    super(0, "too_many_missed_events", message);
    this.name = "TooManyMissedEventsError";
    this.missedCount = missedCount;
    this.replayLimit = replayLimit;
  }
}
```

**Step 2: Commit**

```bash
git add src/errors.ts
git commit -m "feat: add StackCoinError and TooManyMissedEventsError"
```

---

### Task 4: REST client

**Files:**
- Create: `tmp/stackcoin-typescript/src/client.ts`

**Context:** The Python SDK's `client.py` wraps httpx with a `Client` class that has methods for each endpoint. We mirror this but use `openapi-fetch` which gives us type-safe request/response via the generated `paths` type. Each method calls `this.api.GET(...)` or `this.api.POST(...)`, checks for errors, and returns the unwrapped data.

**Key patterns from openapi-fetch:**
- `createClient<paths>({ baseUrl, headers })` creates a typed client
- `const { data, error, response } = await client.GET("/api/path", { params: { ... } })` 
- `error` is populated on non-2xx, `data` on 2xx
- Path params go in `params.path`, query params in `params.query`, body in `body`
- Headers go in `headers` option

**Step 1: Implement the Client class**

```typescript
import createClient from "openapi-fetch";
import type { paths, components } from "./schema.js";
import { StackCoinError } from "./errors.js";

// Re-export useful schema types for consumers
export type User = components["schemas"]["User"];
export type Transaction = components["schemas"]["Transaction"];
export type Request = components["schemas"]["Request"];
export type SendStkResponse = components["schemas"]["SendStkResponse"];
export type CreateRequestResponse = components["schemas"]["CreateRequestResponse"];
export type RequestActionResponse = components["schemas"]["RequestActionResponse"];
export type DiscordGuild = components["schemas"]["DiscordGuild"];
// Event types
export type TransferCompletedEvent = components["schemas"]["TransferCompletedEvent"];
export type RequestCreatedEvent = components["schemas"]["RequestCreatedEvent"];
export type RequestAcceptedEvent = components["schemas"]["RequestAcceptedEvent"];
export type RequestDeniedEvent = components["schemas"]["RequestDeniedEvent"];
export type AnyEvent =
  | TransferCompletedEvent
  | RequestCreatedEvent
  | RequestAcceptedEvent
  | RequestDeniedEvent;

export interface ClientOptions {
  token: string;
  baseUrl?: string;
  timeout?: number;
}

export class Client {
  private api;

  constructor(options: ClientOptions) {
    const { token, baseUrl = "https://stackcoin.world", timeout = 10000 } = options;
    this.api = createClient<paths>({
      baseUrl,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
      },
      // Note: openapi-fetch doesn't support timeout natively,
      // but we can pass signal via middleware or per-request if needed.
    });
  }

  private throwIfError<T>(data: T | undefined, error: unknown, response: Response): T {
    if (error || !data) {
      const body = error as { error?: string; message?: string } | undefined;
      throw new StackCoinError(
        response.status,
        body?.error ?? `http_${response.status}`,
        body?.message,
      );
    }
    return data;
  }

  async getMe(): Promise<User> {
    const { data, error, response } = await this.api.GET("/api/user/me");
    return this.throwIfError(data, error, response);
  }

  async getUser(userId: number): Promise<User> {
    const { data, error, response } = await this.api.GET("/api/user/{user_id}", {
      params: { path: { user_id: userId } },
    });
    return this.throwIfError(data, error, response);
  }

  async getUsers(opts?: { discordId?: string }): Promise<User[]> {
    const { data, error, response } = await this.api.GET("/api/users", {
      params: { query: { discord_id: opts?.discordId } },
    });
    const result = this.throwIfError(data, error, response);
    return result.users ?? [];
  }

  async send(
    toUserId: number,
    amount: number,
    opts?: { label?: string; idempotencyKey?: string },
  ): Promise<SendStkResponse> {
    const { data, error, response } = await this.api.POST("/api/user/{user_id}/send", {
      params: { path: { user_id: toUserId } },
      body: { amount, label: opts?.label },
      headers: opts?.idempotencyKey ? { "Idempotency-Key": opts.idempotencyKey } : undefined,
    });
    return this.throwIfError(data, error, response);
  }

  async createRequest(
    toUserId: number,
    amount: number,
    opts?: { label?: string; idempotencyKey?: string },
  ): Promise<CreateRequestResponse> {
    const { data, error, response } = await this.api.POST("/api/user/{user_id}/request", {
      params: { path: { user_id: toUserId } },
      body: { amount, label: opts?.label },
      headers: opts?.idempotencyKey ? { "Idempotency-Key": opts.idempotencyKey } : undefined,
    });
    return this.throwIfError(data, error, response);
  }

  async getRequest(requestId: number): Promise<Request> {
    const { data, error, response } = await this.api.GET("/api/request/{request_id}", {
      params: { path: { request_id: requestId } },
    });
    return this.throwIfError(data, error, response);
  }

  async getRequests(opts?: { status?: string }): Promise<Request[]> {
    const { data, error, response } = await this.api.GET("/api/requests", {
      params: { query: { status: opts?.status } },
    });
    const result = this.throwIfError(data, error, response);
    return result.requests ?? [];
  }

  async acceptRequest(requestId: number): Promise<RequestActionResponse> {
    const { data, error, response } = await this.api.POST(
      "/api/requests/{request_id}/accept",
      { params: { path: { request_id: requestId } } },
    );
    return this.throwIfError(data, error, response);
  }

  async denyRequest(requestId: number): Promise<RequestActionResponse> {
    const { data, error, response } = await this.api.POST(
      "/api/requests/{request_id}/deny",
      { params: { path: { request_id: requestId } } },
    );
    return this.throwIfError(data, error, response);
  }

  async getTransaction(transactionId: number): Promise<Transaction> {
    const { data, error, response } = await this.api.GET("/api/transaction/{transaction_id}", {
      params: { path: { transaction_id: transactionId } },
    });
    return this.throwIfError(data, error, response);
  }

  async getTransactions(): Promise<Transaction[]> {
    const { data, error, response } = await this.api.GET("/api/transactions");
    const result = this.throwIfError(data, error, response);
    return result.transactions ?? [];
  }

  async getEvents(sinceId: number = 0): Promise<AnyEvent[]> {
    const allEvents: AnyEvent[] = [];
    let cursor = sinceId;

    while (true) {
      const { data, error, response } = await this.api.GET("/api/events", {
        params: { query: { since_id: cursor || undefined } },
      });
      const result = this.throwIfError(data, error, response);
      const page = result.events as AnyEvent[];
      allEvents.push(...page);

      if (!result.has_more || page.length === 0) break;
      cursor = page[page.length - 1].id;
    }

    return allEvents;
  }

  async getDiscordBotId(): Promise<string> {
    const { data, error, response } = await this.api.GET("/api/discord/bot");
    const result = this.throwIfError(data, error, response);
    return result.discord_id;
  }

  async getDiscordGuilds(): Promise<DiscordGuild[]> {
    const { data, error, response } = await this.api.GET("/api/discord/guilds");
    const result = this.throwIfError(data, error, response);
    return result.guilds ?? [];
  }

  async getDiscordGuild(snowflake: string): Promise<DiscordGuild> {
    const { data, error, response } = await this.api.GET("/api/discord/guild/{snowflake}", {
      params: { path: { snowflake } },
    });
    return this.throwIfError(data, error, response);
  }
}
```

**Important notes:**
- The exact shape of `paths` depends on the generated `schema.d.ts`. The path strings and param names must match what `openapi-typescript` generates. After generation, verify the exact path keys (they may use the operationId or the literal path).
- The `events` endpoint returns a discriminated union. openapi-typescript handles `oneOf` + `discriminator` but the exact type shape needs verification after generation.
- Some params/types may need adjustment based on what openapi-typescript actually generates (e.g., `user_id` might be typed as `string` if the spec says so).

**Step 2: Verify types compile**

Run: `pnpm run typecheck` (in `tmp/stackcoin-typescript/`)
Expected: No errors. If there are type errors, fix them based on the actual generated schema shape.

**Step 3: Commit**

```bash
git add src/client.ts
git commit -m "feat: add REST client with all API methods"
```

---

### Task 5: Gateway (WebSocket)

**Files:**
- Create: `tmp/stackcoin-typescript/src/gateway.ts`

**Context:** The Python SDK's `gateway.py` implements the Phoenix Channel v2 protocol over WebSocket. Messages are arrays: `[joinRef, ref, topic, event, payload]`. The gateway joins `user:self`, listens for `"event"` messages, dispatches to handlers, and handles heartbeats + reconnection.

**Step 1: Implement the Gateway class**

```typescript
import type { AnyEvent } from "./client.js";
import type { Client } from "./client.js";
import { TooManyMissedEventsError } from "./errors.js";

export type EventHandler = (event: AnyEvent) => void | Promise<void>;

export interface GatewayOptions {
  token: string;
  wsUrl?: string;
  client?: Client;
  lastEventId?: number;
  onEventId?: (id: number) => void;
}

export class Gateway {
  private wsUrl: string;
  private token: string;
  private client: Client | undefined;
  private handlers: Map<string, EventHandler[]> = new Map();
  private _lastEventId: number | undefined;
  private onEventId: ((id: number) => void) | undefined;
  private ws: WebSocket | null = null;
  private running = false;
  private refCounter = 0;
  private heartbeatInterval: ReturnType<typeof setInterval> | null = null;

  constructor(options: GatewayOptions) {
    this.wsUrl = (options.wsUrl ?? "wss://stackcoin.world/ws").replace(/\/$/, "");
    this.token = options.token;
    this.client = options.client;
    this._lastEventId = options.lastEventId;
    this.onEventId = options.onEventId;
  }

  get lastEventId(): number | undefined {
    return this._lastEventId;
  }

  on(eventType: string, handler: EventHandler): this {
    const existing = this.handlers.get(eventType) ?? [];
    existing.push(handler);
    this.handlers.set(eventType, existing);
    return this;
  }

  async connect(): Promise<void> {
    this.running = true;

    while (this.running) {
      try {
        await this.connectOnce();
      } catch (err) {
        if (err instanceof TooManyMissedEventsError) {
          if (!this.client) throw err;
          await this.catchUpViaRest();
          // Loop back to reconnect with updated cursor
        } else if (this.running) {
          console.warn(`Gateway connection lost: ${err}. Reconnecting in 5s...`);
          await this.sleep(5000);
        }
      }
    }
  }

  stop(): void {
    this.running = false;
    if (this.heartbeatInterval) {
      clearInterval(this.heartbeatInterval);
      this.heartbeatInterval = null;
    }
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }

  private connectOnce(): Promise<void> {
    return new Promise((resolve, reject) => {
      const url = `${this.wsUrl}?token=${this.token}&vsn=2.0.0`;
      const ws = new WebSocket(url);
      this.ws = ws;

      ws.onopen = () => {
        this.joinChannel(ws).then(() => {
          this.startHeartbeat(ws);
        }).catch((err) => {
          ws.close();
          reject(err);
        });
      };

      ws.onmessage = (event) => {
        const msg = JSON.parse(event.data as string);
        this.handleMessage(msg);
      };

      ws.onclose = () => {
        if (this.heartbeatInterval) {
          clearInterval(this.heartbeatInterval);
          this.heartbeatInterval = null;
        }
        resolve(); // Resolve to trigger reconnect loop
      };

      ws.onerror = (err) => {
        reject(err);
      };
    });
  }

  private async joinChannel(ws: WebSocket): Promise<void> {
    this.refCounter++;
    const joinPayload: Record<string, unknown> = {};
    if (this._lastEventId !== undefined) {
      joinPayload.last_event_id = this._lastEventId;
    }

    const joinMsg = JSON.stringify([
      null,
      String(this.refCounter),
      "user:self",
      "phx_join",
      joinPayload,
    ]);
    ws.send(joinMsg);

    // Wait for join reply
    const reply = await this.waitForMessage(ws, 10000);
    if (reply[3] === "phx_reply" && reply[4]?.status === "ok") {
      return;
    }

    const response = reply[4]?.response;
    if (response?.reason === "too_many_missed_events") {
      throw new TooManyMissedEventsError(
        response.missed_count ?? 0,
        response.replay_limit ?? 0,
        response.message ?? "Too many missed events",
      );
    }

    throw new Error(`Failed to join channel: ${JSON.stringify(reply)}`);
  }

  private waitForMessage(ws: WebSocket, timeoutMs: number): Promise<any[]> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        ws.removeEventListener("message", handler);
        reject(new Error("Timed out waiting for join reply"));
      }, timeoutMs);

      const handler = (event: MessageEvent) => {
        clearTimeout(timeout);
        ws.removeEventListener("message", handler);
        resolve(JSON.parse(event.data as string));
      };

      ws.addEventListener("message", handler);
    });
  }

  private startHeartbeat(ws: WebSocket): void {
    this.heartbeatInterval = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) {
        this.refCounter++;
        const hb = JSON.stringify([null, String(this.refCounter), "phoenix", "heartbeat", {}]);
        ws.send(hb);
      }
    }, 30000);
  }

  private handleMessage(msg: any[]): void {
    if (!Array.isArray(msg) || msg.length < 5) return;
    const eventName = msg[3];
    const payload = msg[4];

    if (eventName === "event") {
      this.dispatchEvent(payload as AnyEvent);
    }
  }

  private async dispatchEvent(event: AnyEvent): Promise<void> {
    if (this._lastEventId === undefined || event.id > this._lastEventId) {
      this._lastEventId = event.id;
    }

    const handlers = this.handlers.get(event.type) ?? [];
    for (const handler of handlers) {
      try {
        await handler(event);
      } catch (err) {
        console.error(`Error in ${event.type} handler for event ${event.id}:`, err);
      }
    }

    if (event.id > 0 && this.onEventId) {
      try {
        this.onEventId(event.id);
      } catch (err) {
        console.error(`Error in onEventId callback for event ${event.id}:`, err);
      }
    }
  }

  private async catchUpViaRest(): Promise<void> {
    if (!this.client) {
      throw new Error("Cannot catch up via REST without a client");
    }
    const events = await this.client.getEvents(this._lastEventId ?? 0);
    for (const event of events) {
      await this.dispatchEvent(event);
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
```

**Step 2: Verify types compile**

Run: `pnpm run typecheck`
Expected: No errors.

**Step 3: Commit**

```bash
git add src/gateway.ts
git commit -m "feat: add WebSocket gateway with Phoenix Channel protocol"
```

---

### Task 6: Public API exports (index.ts)

**Files:**
- Create: `tmp/stackcoin-typescript/src/index.ts`

**Step 1: Create index.ts with all public exports**

```typescript
// Client
export { Client } from "./client.js";
export type { ClientOptions } from "./client.js";

// Gateway
export { Gateway } from "./gateway.js";
export type { GatewayOptions, EventHandler } from "./gateway.js";

// Errors
export { StackCoinError, TooManyMissedEventsError } from "./errors.js";

// Types re-exported from generated schema (via client.ts)
export type {
  User,
  Transaction,
  Request,
  SendStkResponse,
  CreateRequestResponse,
  RequestActionResponse,
  DiscordGuild,
  TransferCompletedEvent,
  RequestCreatedEvent,
  RequestAcceptedEvent,
  RequestDeniedEvent,
  AnyEvent,
} from "./client.js";
```

**Step 2: Verify types compile and build succeeds**

Run: `pnpm run typecheck && pnpm run build`
Expected: No type errors. `dist/` created with `index.js`, `index.d.ts`.

**Step 3: Commit**

```bash
git add src/index.ts
git commit -m "feat: add public API exports"
```

---

### Task 7: Build verification and fix any issues

**Step 1: Run full build**

Run: `pnpm run build` (in `tmp/stackcoin-typescript/`)
Expected: `dist/index.js` and `dist/index.d.ts` created without errors.

**Step 2: Verify dist contents look correct**

Check that `dist/index.js` exports Client, Gateway, errors.
Check that `dist/index.d.ts` exports all types.

**Step 3: Fix any build issues**

If there are type mismatches between the generated schema and the client code, adjust the client code to match the actual generated types. Common issues:
- Path parameter names may differ from what we assumed
- Response types may be wrapped differently
- The events discriminated union may need special handling

**Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve build issues"
```

---

### Task 8: Examples

**Files:**
- Create: `tmp/stackcoin-typescript/examples/basic-usage.ts`
- Create: `tmp/stackcoin-typescript/examples/gateway.ts`

**Step 1: Create basic-usage.ts**

Port from Python SDK's `examples/basic_usage.py`. Should demonstrate:
- Creating a client with token
- `getMe()`, `getUsers()`, `getTransactions()`, `createRequest()`
- Error handling with try/catch

**Step 2: Create gateway.ts**

Port from Python SDK's `examples/simple_cli.py` gateway portion. Should demonstrate:
- Creating a gateway with event handlers using `.on()`
- Running alongside a REST client
- Handler registration for all 4 event types

**Step 3: Commit**

```bash
git add examples/
git commit -m "feat: add usage examples for REST client and gateway"
```

---

### Task 9: Final verification

**Step 1: Clean build from scratch**

Run: `rm -rf dist node_modules && pnpm install && pnpm run build`
Expected: Build succeeds, dist/ has index.js + index.d.ts + source maps.

**Step 2: Verify package is publishable**

Run: `pnpm pack --dry-run`
Expected: Shows files that would be included (dist/, package.json, README.md).

**Step 3: Typecheck**

Run: `pnpm run typecheck`
Expected: No errors.

**Step 4: Commit any final adjustments**

```bash
git add -A
git commit -m "chore: final build verification"
```
