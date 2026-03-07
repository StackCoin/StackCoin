# StackCoin TypeScript SDK Design

## Overview

A TypeScript client library for the StackCoin API, published as `stackcoin` on npm. Mirrors the Python SDK's functionality with idiomatic TypeScript patterns. Uses `openapi-typescript` to generate types from `openapi.json` and `openapi-fetch` for a type-safe HTTP client.

## Architecture

```
stackcoin-typescript/
├── src/
│   ├── index.ts              # Public API exports
│   ├── client.ts             # REST client wrapping openapi-fetch
│   ├── gateway.ts            # Phoenix Channel WebSocket gateway
│   ├── errors.ts             # StackCoinError, TooManyMissedEventsError
│   └── schema.d.ts           # Generated types from openapi.json
├── examples/
│   ├── basic-usage.ts        # REST client demo
│   └── gateway.ts            # Gateway with event handlers
├── package.json
├── tsconfig.json
├── tsup.config.ts
├── justfile
└── README.md
```

## Type Generation

- `openapi-typescript` generates `src/schema.d.ts` from `../../openapi.json`
- A `just generate` command regenerates types (matches Python SDK pattern)
- Types are compile-time only -- no Zod, no runtime validation

## REST Client

Wraps `openapi-fetch`'s `createClient<paths>()` with a higher-level `Client` class.

**Constructor:** `new Client({ token, baseUrl?, timeout? })`

Default `baseUrl`: `https://stackcoin.world`
Default `timeout`: 10000ms

**Methods** (mirrors Python SDK):

| Method | Return Type | Endpoint |
|--------|------------|----------|
| `getMe()` | `User` | `GET /api/user/me` |
| `getUser(userId)` | `User` | `GET /api/user/{user_id}` |
| `getUsers(opts?)` | `User[]` | `GET /api/users` |
| `send(toUserId, amount, opts?)` | `SendStkResponse` | `POST /api/user/{user_id}/send` |
| `createRequest(toUserId, amount, opts?)` | `CreateRequestResponse` | `POST /api/user/{user_id}/request` |
| `getRequest(id)` | `Request` | `GET /api/request/{request_id}` |
| `getRequests(opts?)` | `Request[]` | `GET /api/requests` |
| `acceptRequest(id)` | `RequestActionResponse` | `POST /api/requests/{request_id}/accept` |
| `denyRequest(id)` | `RequestActionResponse` | `POST /api/requests/{request_id}/deny` |
| `getTransaction(id)` | `Transaction` | `GET /api/transaction/{transaction_id}` |
| `getTransactions(opts?)` | `Transaction[]` | `GET /api/transactions` |
| `getEvents(sinceId?)` | `Event[]` | `GET /api/events` (auto-paginates) |
| `getDiscordBotId()` | `string` | `GET /api/discord/bot` |
| `getDiscordGuilds()` | `DiscordGuild[]` | `GET /api/discord/guilds` |
| `getDiscordGuild(snowflake)` | `DiscordGuild` | `GET /api/discord/guild/{snowflake}` |

**Error handling:** Non-2xx responses throw `StackCoinError` with status code and parsed error body.

**List methods** return unwrapped arrays (e.g., `getUsers()` returns `User[]`, not the pagination wrapper).

**`getEvents()`** auto-paginates by looping with `has_more` cursor, matching Python SDK behavior.

## Gateway

Raw WebSocket implementation of the Phoenix Channel protocol (v2.0.0).

- Uses native `WebSocket` (Node 21+, Deno, Bun, browsers)
- Connects to `wss://stackcoin.world/ws`
- Joins `user:self` channel with optional `last_event_id` for replay
- Event handler registration: `.on("transfer.completed", handler)`
- Auto-reconnect with 5s delay on connection loss
- 30s heartbeat loop
- Catch-up via REST client when >100 events missed (raises `TooManyMissedEventsError` if no client provided)
- Cursor tracking with `onEventId` callback for persistence

## Build & Distribution

- **Package manager:** pnpm
- **Build tool:** tsup -- ESM-only output to `dist/`
- **Target:** ES2022 (Node 21+ native WebSocket)
- **Package name:** `stackcoin`
- **License:** MIT
- **Runtime dependencies:** `openapi-fetch`
- **Dev dependencies:** `openapi-typescript`, `typescript`, `tsup`
- **Node engines:** `>=21.0.0`

## Decisions

- **No Zod/runtime validation:** openapi-fetch provides type-level safety for request/response discrimination. Runtime validation adds bundle size with limited benefit for a thin API client.
- **No CJS output:** ESM-only keeps the build simple. Node 21+ supports ESM natively.
- **Raw WebSocket over phoenix JS client:** Matches Python SDK approach. Zero extra dependencies, full control over the protocol.
- **Native WebSocket over `ws` package:** Eliminates a dependency. Limits to Node 21+ but that's acceptable given the ESM-only target.
