# StackCoin Python SDK Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the auto-generated `stackcoin-python` client with an ergonomic SDK that combines generated Pydantic v2 models, a handwritten async REST client, and a WebSocket gateway -- then migrate LuckyPot to use it.

**Architecture:** Models are generated from `openapi.json` via `datamodel-codegen`. The REST client is a thin async wrapper around httpx that returns typed models and raises `StackCoinError` on failure. The gateway is a WebSocket client speaking the Phoenix Channel protocol. Both are independent classes sharing credentials.

**Tech Stack:** Python 3.13, Pydantic v2, httpx, websockets, datamodel-codegen (tool-installed via uv)

---

## Phase 1: Build the stackcoin SDK

### Task 1: Clean out old generated code and set up package structure

**Files:**
- Delete: `tmp/stackcoin-python/stackcoin/stackcoin_python/` (entire directory)
- Delete: `tmp/stackcoin-python/stackcoin/README.md`
- Delete: `tmp/stackcoin-python/openapi-python-client-config.yml`
- Rewrite: `tmp/stackcoin-python/stackcoin/pyproject.toml`
- Create: `tmp/stackcoin-python/stackcoin/stackcoin/__init__.py`
- Create: `tmp/stackcoin-python/stackcoin/stackcoin/errors.py`
- Rewrite: `tmp/stackcoin-python/justfile`

The old package structure was `stackcoin/stackcoin_python/`. The new one is `stackcoin/stackcoin/` (the inner `stackcoin` is the Python package).

**Step 1: Delete old generated code**

```bash
rm -rf tmp/stackcoin-python/stackcoin/stackcoin_python
rm -f tmp/stackcoin-python/stackcoin/README.md
rm -f tmp/stackcoin-python/openapi-python-client-config.yml
```

**Step 2: Rewrite pyproject.toml**

`tmp/stackcoin-python/stackcoin/pyproject.toml`:

```toml
[project]
name = "stackcoin"
version = "0.1.0"
description = "Python SDK for the StackCoin API"
requires-python = ">=3.13"
dependencies = [
    "httpx>=0.27",
    "pydantic>=2.0",
    "websockets>=13.0",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["stackcoin"]

[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["F", "I", "UP"]
```

**Step 3: Create errors.py**

`tmp/stackcoin-python/stackcoin/stackcoin/errors.py`:

```python
class StackCoinError(Exception):
    """Raised when the StackCoin API returns an error response."""

    def __init__(self, status_code: int, error: str, message: str | None = None):
        self.status_code = status_code
        self.error = error
        self.message = message
        super().__init__(f"{status_code} {error}: {message}")
```

**Step 4: Create `__init__.py` (placeholder, will be filled in later tasks)**

`tmp/stackcoin-python/stackcoin/stackcoin/__init__.py`:

```python
"""StackCoin Python SDK."""

from .errors import StackCoinError

__all__ = ["StackCoinError"]
```

**Step 5: Rewrite the justfile**

`tmp/stackcoin-python/justfile`:

```just
generate:
  datamodel-codegen \
    --input ../../openapi.json \
    --input-file-type openapi \
    --output-model-type pydantic_v2.BaseModel \
    --output stackcoin/stackcoin/models.py \
    --target-python-version 3.13
  uvx ruff format stackcoin/

dev:
  uv pip install -e "stackcoin @ ./stackcoin"
```

**Step 6: Commit**

```bash
git add tmp/stackcoin-python/
git commit -m "chore: clean out old generated stackcoin-python, set up new SDK structure"
```

---

### Task 2: Generate models from OpenAPI spec

**Files:**
- Generate: `tmp/stackcoin-python/stackcoin/stackcoin/models.py`

**Step 1: Ensure openapi.json is up to date**

Run from the StackCoin root:
```bash
just openapi
```

Verify: `openapi.json` exists in the repo root and contains the latest spec.

**Step 2: Generate models**

Run from `tmp/stackcoin-python/`:
```bash
just generate
```

This runs `datamodel-codegen` and `ruff format`.

**Step 3: Verify the generated file**

Read `tmp/stackcoin-python/stackcoin/stackcoin/models.py` and verify it contains Pydantic v2 models for at least: `User`, `SendStkResponse`, `SendStkParams`, `CreateRequestResponse`, `CreateRequestParams`, `ErrorResponse`, `RequestActionResponse`, `Transaction`, `Request`, `DiscordGuild`.

If the generated output has issues (e.g., unnecessary wrapper classes, naming oddities), adjust `datamodel-codegen` flags. Useful flags to try:
- `--use-standard-collections` (use `list` not `List`)
- `--use-union-operator` (use `X | Y` not `Union[X, Y]`)
- `--field-constraints` (include field validators)
- `--collapse-root-models` (inline single-field wrapper models)
- `--use-default-kwarg` (use `= None` instead of `Field(default=None)`)

Re-run `just generate` after any flag changes.

**Step 4: Commit**

```bash
git add tmp/stackcoin-python/stackcoin/stackcoin/models.py
git commit -m "feat: generate Pydantic v2 models from OpenAPI spec"
```

---

### Task 3: Write the REST client

**Files:**
- Create: `tmp/stackcoin-python/stackcoin/stackcoin/client.py`
- Modify: `tmp/stackcoin-python/stackcoin/stackcoin/__init__.py`

**Step 1: Write client.py**

`tmp/stackcoin-python/stackcoin/stackcoin/client.py`:

```python
"""Async REST client for the StackCoin API."""

from typing import Any

import httpx

from .errors import StackCoinError
from .models import (
    CreateRequestResponse,
    DiscordGuild,
    DiscordGuildsResponse,
    DiscordGuildResponse,
    Request,
    RequestActionResponse,
    RequestResponse,
    RequestsResponse,
    SendStkResponse,
    Transaction,
    TransactionResponse,
    TransactionsResponse,
    User,
    UserResponse,
    UsersResponse,
)


class Client:
    """Async StackCoin API client.

    Usage::

        async with stackcoin.Client(base_url="http://localhost:4000", token="...") as client:
            me = await client.get_me()
            print(me.balance)
    """

    def __init__(self, base_url: str, token: str, timeout: float = 10.0):
        self._http = httpx.AsyncClient(
            base_url=base_url,
            headers={"Authorization": f"Bearer {token}"},
            timeout=timeout,
        )

    async def close(self) -> None:
        await self._http.aclose()

    async def __aenter__(self) -> "Client":
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.close()

    # -- internal helpers --

    def _raise_for_error(self, resp: httpx.Response) -> None:
        """Raise StackCoinError if the response is not successful."""
        if resp.status_code >= 400:
            try:
                data = resp.json()
                raise StackCoinError(
                    status_code=resp.status_code,
                    error=data.get("error", "unknown"),
                    message=data.get("message"),
                )
            except (ValueError, KeyError):
                raise StackCoinError(
                    status_code=resp.status_code,
                    error="unknown",
                    message=resp.text,
                )

    def _extra_headers(self, idempotency_key: str | None = None) -> dict[str, str]:
        headers: dict[str, str] = {}
        if idempotency_key:
            headers["Idempotency-Key"] = idempotency_key
        return headers

    # -- User endpoints --

    async def get_me(self) -> User:
        """Get the authenticated user's profile."""
        resp = await self._http.get("/api/user/me")
        self._raise_for_error(resp)
        return UserResponse.model_validate(resp.json()).user

    async def get_user(self, user_id: int) -> User:
        """Get a user by ID."""
        resp = await self._http.get(f"/api/user/{user_id}")
        self._raise_for_error(resp)
        return UserResponse.model_validate(resp.json()).user

    async def get_users(self, discord_id: str | None = None) -> list[User]:
        """List users, optionally filtered by Discord ID."""
        params: dict[str, str] = {}
        if discord_id:
            params["discord_id"] = discord_id
        resp = await self._http.get("/api/users", params=params)
        self._raise_for_error(resp)
        return UsersResponse.model_validate(resp.json()).users

    # -- Transfer endpoints --

    async def send(
        self,
        to_user_id: int,
        amount: int,
        label: str | None = None,
        idempotency_key: str | None = None,
    ) -> SendStkResponse:
        """Send STK to a user."""
        payload: dict[str, Any] = {"amount": amount}
        if label:
            payload["label"] = label
        resp = await self._http.post(
            f"/api/user/{to_user_id}/send",
            json=payload,
            headers=self._extra_headers(idempotency_key),
        )
        self._raise_for_error(resp)
        return SendStkResponse.model_validate(resp.json())

    # -- Request endpoints --

    async def create_request(
        self,
        to_user_id: int,
        amount: int,
        label: str | None = None,
        idempotency_key: str | None = None,
    ) -> CreateRequestResponse:
        """Create a payment request to a user."""
        payload: dict[str, Any] = {"amount": amount}
        if label:
            payload["label"] = label
        resp = await self._http.post(
            f"/api/user/{to_user_id}/request",
            json=payload,
            headers=self._extra_headers(idempotency_key),
        )
        self._raise_for_error(resp)
        return CreateRequestResponse.model_validate(resp.json())

    async def get_request(self, request_id: int) -> Request:
        """Get a request by ID."""
        resp = await self._http.get(f"/api/request/{request_id}")
        self._raise_for_error(resp)
        return RequestResponse.model_validate(resp.json()).request

    async def get_requests(self, status: str | None = None) -> list[Request]:
        """List requests, optionally filtered by status."""
        params: dict[str, str] = {}
        if status:
            params["status"] = status
        resp = await self._http.get("/api/requests", params=params)
        self._raise_for_error(resp)
        return RequestsResponse.model_validate(resp.json()).requests

    async def accept_request(self, request_id: int) -> RequestActionResponse:
        """Accept a payment request."""
        resp = await self._http.post(f"/api/requests/{request_id}/accept")
        self._raise_for_error(resp)
        return RequestActionResponse.model_validate(resp.json())

    async def deny_request(self, request_id: int) -> RequestActionResponse:
        """Deny a payment request."""
        resp = await self._http.post(f"/api/requests/{request_id}/deny")
        self._raise_for_error(resp)
        return RequestActionResponse.model_validate(resp.json())

    # -- Transaction endpoints --

    async def get_transactions(self) -> list[Transaction]:
        """List transactions."""
        resp = await self._http.get("/api/transactions")
        self._raise_for_error(resp)
        return TransactionsResponse.model_validate(resp.json()).transactions

    async def get_transaction(self, transaction_id: int) -> Transaction:
        """Get a transaction by ID."""
        resp = await self._http.get(f"/api/transaction/{transaction_id}")
        self._raise_for_error(resp)
        return TransactionResponse.model_validate(resp.json()).transaction

    # -- Event endpoints --

    async def get_events(self, since_id: int = 0) -> list[dict[str, Any]]:
        """Get events since a given event ID (REST fallback for gateway)."""
        params: dict[str, str] = {}
        if since_id > 0:
            params["since_id"] = str(since_id)
        resp = await self._http.get("/api/events", params=params)
        self._raise_for_error(resp)
        return resp.json().get("events", [])

    # -- Discord endpoints --

    async def get_discord_guilds(self) -> list[DiscordGuild]:
        """List Discord guilds."""
        resp = await self._http.get("/api/discord/guilds")
        self._raise_for_error(resp)
        return DiscordGuildsResponse.model_validate(resp.json()).guilds

    async def get_discord_guild(self, snowflake: str) -> DiscordGuild:
        """Get a Discord guild by snowflake ID."""
        resp = await self._http.get(f"/api/discord/guild/{snowflake}")
        self._raise_for_error(resp)
        return DiscordGuildResponse.model_validate(resp.json()).guild
```

**Important:** The exact model names (`UserResponse`, `UsersResponse`, etc.) and their field names (`.user`, `.users`, `.transaction`, etc.) depend on what `datamodel-codegen` produces in Task 2. After generating models, verify these names match and adjust imports/field access accordingly. The generated models may use different wrapper structures -- adapt the client to match.

**Step 2: Update `__init__.py`**

```python
"""StackCoin Python SDK."""

from .client import Client
from .errors import StackCoinError
from .gateway import Event, Gateway

__all__ = ["Client", "Gateway", "Event", "StackCoinError"]
```

Note: This references `gateway.py` which doesn't exist yet -- that's Task 4. For now, comment out the gateway imports until Task 4 is done, or write them both together.

**Step 3: Commit**

```bash
git add tmp/stackcoin-python/stackcoin/stackcoin/client.py tmp/stackcoin-python/stackcoin/stackcoin/__init__.py
git commit -m "feat: add handwritten async REST client for StackCoin API"
```

---

### Task 4: Write the WebSocket gateway

**Files:**
- Create: `tmp/stackcoin-python/stackcoin/stackcoin/gateway.py`
- Modify: `tmp/stackcoin-python/stackcoin/stackcoin/__init__.py` (uncomment gateway imports)

This is adapted from `tmp/LuckyPot/luckypot/gateway.py` with the addition of a typed `Event` model.

**Step 1: Write gateway.py**

`tmp/stackcoin-python/stackcoin/stackcoin/gateway.py`:

```python
"""StackCoin WebSocket Gateway client.

Connects to the StackCoin Phoenix Channel WebSocket and receives
real-time events. Handles reconnection and event replay.
"""

import asyncio
import json
from typing import Any, Callable, Awaitable

from pydantic import BaseModel


EventHandler = Callable[["Event"], Awaitable[None]]


class Event(BaseModel):
    """A StackCoin event received via the gateway or REST API."""

    id: int
    type: str
    data: dict[str, Any]
    inserted_at: str


class Gateway:
    """WebSocket gateway for receiving real-time StackCoin events.

    Usage::

        gateway = stackcoin.Gateway(
            ws_url="ws://localhost:4000/bot/websocket",
            token="...",
        )

        @gateway.on("request.accepted")
        async def handle_accepted(event: stackcoin.Event):
            print(event.data["request_id"])

        await gateway.connect()
    """

    def __init__(
        self,
        ws_url: str,
        token: str,
        last_event_id: int = 0,
        on_event_id: Callable[[int], None] | None = None,
    ):
        self._ws_url = ws_url.rstrip("/")
        self._token = token
        self._handlers: dict[str, list[EventHandler]] = {}
        self._last_event_id = last_event_id
        self._on_event_id = on_event_id
        self._ws = None
        self._running = False
        self._ref_counter = 0

    @property
    def last_event_id(self) -> int:
        return self._last_event_id

    def on(self, event_type: str) -> Callable[[EventHandler], EventHandler]:
        """Decorator to register an event handler."""

        def decorator(func: EventHandler) -> EventHandler:
            self.register_handler(event_type, func)
            return func

        return decorator

    def register_handler(self, event_type: str, handler: EventHandler) -> None:
        """Register an event handler programmatically."""
        if event_type not in self._handlers:
            self._handlers[event_type] = []
        self._handlers[event_type].append(handler)

    async def connect(self) -> None:
        """Connect and listen for events. Reconnects automatically on failure."""
        import websockets

        self._running = True

        while self._running:
            try:
                url = f"{self._ws_url}?token={self._token}&vsn=2.0.0"

                async with websockets.connect(url) as ws:
                    self._ws = ws
                    await self._join_channel(ws)

                    heartbeat_task = asyncio.create_task(self._heartbeat(ws))
                    try:
                        async for raw_msg in ws:
                            msg = json.loads(raw_msg)
                            await self._handle_message(msg)
                    finally:
                        heartbeat_task.cancel()

            except Exception:
                if self._running:
                    await asyncio.sleep(5)

    async def _join_channel(self, ws: Any) -> None:
        """Join the user:self channel with event replay."""
        self._ref_counter += 1
        join_msg = json.dumps(
            [
                None,
                str(self._ref_counter),
                "user:self",
                "phx_join",
                {"last_event_id": self._last_event_id},
            ]
        )
        await ws.send(join_msg)

        reply = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
        if not (reply[3] == "phx_reply" and reply[4].get("status") == "ok"):
            raise ConnectionError(f"Failed to join channel: {reply}")

    async def _heartbeat(self, ws: Any) -> None:
        """Send periodic heartbeats to keep the connection alive."""
        while True:
            await asyncio.sleep(30)
            self._ref_counter += 1
            hb = json.dumps([None, str(self._ref_counter), "phoenix", "heartbeat", {}])
            await ws.send(hb)

    async def _handle_message(self, msg: list[Any]) -> None:
        """Dispatch an incoming message to registered handlers."""
        if len(msg) < 5:
            return

        event_name = msg[3]
        payload = msg[4]

        if event_name == "event":
            event = Event.model_validate(payload)

            if event.id > self._last_event_id:
                self._last_event_id = event.id

            for handler in self._handlers.get(event.type, []):
                try:
                    await handler(event)
                except Exception:
                    pass  # handlers should handle their own errors

            if event.id > 0 and self._on_event_id:
                try:
                    self._on_event_id(event.id)
                except Exception:
                    pass

    def stop(self) -> None:
        """Signal the gateway to stop reconnecting and disconnect."""
        self._running = False
```

**Key difference from LuckyPot's gateway.py:** Handlers receive a typed `Event` object instead of a raw `dict`. The `on_event_id` callback is preserved for cursor persistence.

**Step 2: Update `__init__.py` with gateway imports**

Ensure the `__init__.py` has:

```python
"""StackCoin Python SDK."""

from .client import Client
from .errors import StackCoinError
from .gateway import Event, Gateway

__all__ = ["Client", "Event", "Gateway", "StackCoinError"]
```

**Step 3: Commit**

```bash
git add tmp/stackcoin-python/stackcoin/stackcoin/gateway.py tmp/stackcoin-python/stackcoin/stackcoin/__init__.py
git commit -m "feat: add WebSocket gateway with typed Event model"
```

---

### Task 5: Install and smoke test the SDK

**Step 1: Install the SDK in development mode**

From `tmp/stackcoin-python/`:
```bash
just dev
```

Or directly:
```bash
uv pip install -e "stackcoin @ ./stackcoin"
```

Expected: Installs successfully.

**Step 2: Verify imports work**

```bash
python -c "import stackcoin; print(stackcoin.Client, stackcoin.Gateway, stackcoin.Event, stackcoin.StackCoinError)"
```

Expected: Prints the four classes without import errors.

**Step 3: Verify model imports**

```bash
python -c "from stackcoin.models import User, SendStkResponse, CreateRequestResponse, ErrorResponse; print('Models OK')"
```

Expected: `Models OK`

**Step 4: Commit if any fixes were needed**

If Task 2's model generation required flag adjustments or Task 3's client needed model name fixes, commit those now:

```bash
git add tmp/stackcoin-python/
git commit -m "fix: adjust SDK based on smoke test"
```

---

## Phase 2: Migrate LuckyPot to use the new SDK

### Task 6: Update LuckyPot dependencies

**Files:**
- Modify: `tmp/LuckyPot/pyproject.toml`

**Step 1: Add stackcoin dependency, remove httpx (it's now transitive)**

In `tmp/LuckyPot/pyproject.toml`, update the dependencies. Replace `httpx` with `stackcoin` (editable local install during development). Keep `websockets` since the gateway needs it at runtime but it's also transitive via stackcoin.

```toml
[project]
name = "luckypot"
version = "0.1.0"
description = "LuckyPot is a bot that implements a lottery system on top of StackCoin"
readme = "README.md"
requires-python = ">=3.13"
dependencies = [
    "hikari>=2.3.5",
    "hikari-lightbulb>=3.1.1",
    "loguru>=0.7.3",
    "pydantic-settings>=2.0",
    "stackcoin>=0.1.0",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["luckypot"]
```

**Step 2: Install updated deps**

From `tmp/LuckyPot/`:
```bash
uv pip install -e "../../tmp/stackcoin-python/stackcoin"
uv pip install -e .
```

**Step 3: Commit**

```bash
git add tmp/LuckyPot/pyproject.toml
git commit -m "chore: add stackcoin SDK dependency to LuckyPot"
```

---

### Task 7: Rewrite LuckyPot's stk.py to use stackcoin SDK

**Files:**
- Rewrite: `tmp/LuckyPot/luckypot/stk.py`

The current `stk.py` has 7 functions making raw httpx calls returning `dict | None`. Replace with a thin wrapper that exposes a `stackcoin.Client` singleton.

**Step 1: Rewrite stk.py**

`tmp/LuckyPot/luckypot/stk.py`:

```python
"""StackCoin API access for LuckyPot.

Thin wrapper around the stackcoin SDK that manages a shared Client instance
configured from LuckyPot's settings.
"""

import stackcoin
from loguru import logger

from luckypot.config import settings

_client: stackcoin.Client | None = None


def get_client() -> stackcoin.Client:
    """Get or create the shared StackCoin client."""
    global _client
    if _client is None:
        _client = stackcoin.Client(
            base_url=settings.stackcoin_api_url,
            token=settings.stackcoin_api_token,
        )
    return _client


def reset_client() -> None:
    """Reset the client (for testing or config changes)."""
    global _client
    _client = None


async def get_user_by_discord_id(discord_id: str) -> dict | None:
    """Look up a StackCoin user by their Discord ID.

    Returns the user as a dict for backward compatibility with game.py.
    """
    try:
        users = await get_client().get_users(discord_id=discord_id)
        if not users:
            return None
        user = users[0]
        return {"id": user.id, "username": user.username, "balance": user.balance}
    except stackcoin.StackCoinError as e:
        logger.error(f"Failed to look up user by discord_id={discord_id}: {e}")
        return None


async def get_bot_user() -> dict | None:
    """Get the bot's own StackCoin user profile."""
    try:
        user = await get_client().get_me()
        return {"id": user.id, "username": user.username, "balance": user.balance}
    except stackcoin.StackCoinError as e:
        logger.error(f"Failed to get bot user: {e}")
        return None


async def get_bot_balance() -> int | None:
    """Get the bot's current STK balance."""
    try:
        user = await get_client().get_me()
        return user.balance
    except stackcoin.StackCoinError as e:
        logger.error(f"Failed to get bot balance: {e}")
        return None


async def send_stk(
    to_user_id: int, amount: int, label: str | None = None, idempotency_key: str | None = None
) -> dict | None:
    """Send STK to a user. Returns response dict or None on failure."""
    try:
        result = await get_client().send(
            to_user_id=to_user_id, amount=amount, label=label, idempotency_key=idempotency_key
        )
        return {
            "success": result.success,
            "transaction_id": result.transaction_id,
            "amount": result.amount,
            "from_new_balance": result.from_new_balance,
            "to_new_balance": result.to_new_balance,
        }
    except stackcoin.StackCoinError as e:
        logger.error(f"Failed to send {amount} STK to user {to_user_id}: {e}")
        return None


async def create_request(
    to_user_id: int, amount: int, label: str | None = None, idempotency_key: str | None = None
) -> dict | None:
    """Create a payment request. Returns response dict or None on failure."""
    try:
        result = await get_client().create_request(
            to_user_id=to_user_id, amount=amount, label=label, idempotency_key=idempotency_key
        )
        return {
            "success": result.success,
            "request_id": result.request_id,
            "amount": result.amount,
            "status": result.status,
        }
    except stackcoin.StackCoinError as e:
        logger.error(f"Failed to create request for {amount} STK from user {to_user_id}: {e}")
        return None


async def get_request(request_id: int) -> dict | None:
    """Get a request by ID."""
    try:
        req = await get_client().get_request(request_id=request_id)
        return {
            "id": req.id,
            "amount": req.amount,
            "status": req.status,
        }
    except stackcoin.StackCoinError as e:
        logger.error(f"Failed to get request {request_id}: {e}")
        return None


async def get_guild_channel(guild_id: str) -> str | None:
    """Get the designated channel for a Discord guild."""
    try:
        guild = await get_client().get_discord_guild(snowflake=guild_id)
        return guild.designated_channel_snowflake
    except stackcoin.StackCoinError:
        return None
```

**Design note:** This task preserves the `dict | None` return interface that `game.py` currently expects. This is a deliberate choice -- migrate in two steps. First swap the HTTP layer (this task), then optionally migrate game.py to use typed models directly in a future task. This way we can run E2E tests after this step to verify nothing broke.

**Step 2: Commit**

```bash
git add tmp/LuckyPot/luckypot/stk.py
git commit -m "refactor: rewrite stk.py to use stackcoin SDK instead of raw httpx"
```

---

### Task 8: Update LuckyPot's gateway usage

**Files:**
- Modify: `tmp/LuckyPot/lucky_pot.py`
- Delete: `tmp/LuckyPot/luckypot/gateway.py` (replaced by stackcoin.Gateway)

The current `lucky_pot.py` imports `StackCoinGateway` from `luckypot.gateway`. Replace with `stackcoin.Gateway`. The handler signatures change: they now receive a `stackcoin.Event` instead of a raw dict.

**Step 1: Update lucky_pot.py**

The key change is in the `on_started` handler. Replace:

```python
from luckypot.gateway import StackCoinGateway
```

with:

```python
import stackcoin
```

And replace the gateway setup block:

```python
    gateway = StackCoinGateway(
        settings.stackcoin_ws_url,
        settings.stackcoin_api_token,
        last_event_id=last_event_id,
        on_event_id=persist_event_id,
    )

    async def handle_accepted(payload):
        await on_request_accepted(payload.get("data", {}), announce=announce)

    async def handle_denied(payload):
        await on_request_denied(payload.get("data", {}), announce=announce)

    gateway.register_handler("request.accepted", handle_accepted)
    gateway.register_handler("request.denied", handle_denied)
```

With:

```python
    gateway = stackcoin.Gateway(
        ws_url=settings.stackcoin_ws_url,
        token=settings.stackcoin_api_token,
        last_event_id=last_event_id,
        on_event_id=persist_event_id,
    )

    async def handle_accepted(event: stackcoin.Event):
        await on_request_accepted(event.data, announce=announce)

    async def handle_denied(event: stackcoin.Event):
        await on_request_denied(event.data, announce=announce)

    gateway.register_handler("request.accepted", handle_accepted)
    gateway.register_handler("request.denied", handle_denied)
```

The difference: `event.data` instead of `payload.get("data", {})`, since the gateway now parses the Phoenix Channel message into a typed `Event` and handlers receive the `Event` directly.

**Step 2: Delete LuckyPot's gateway.py**

```bash
rm tmp/LuckyPot/luckypot/gateway.py
```

**Step 3: Verify no other imports of the old gateway**

Search for remaining references to `luckypot.gateway` or `StackCoinGateway`:

```bash
grep -r "luckypot.gateway\|StackCoinGateway" tmp/LuckyPot/ --include="*.py"
```

Expected: No matches (only `lucky_pot.py` imported it, which we just changed).

**Step 4: Commit**

```bash
git add tmp/LuckyPot/lucky_pot.py
git rm tmp/LuckyPot/luckypot/gateway.py
git commit -m "refactor: use stackcoin.Gateway instead of LuckyPot's own gateway"
```

---

### Task 9: Update LuckyPot's stk.py reset in conftest for E2E tests

**Files:**
- Modify: `test/e2e/conftest.py`

The E2E test fixtures currently patch `settings.stackcoin_api_url` and `settings.stackcoin_api_token` directly. Since `stk.py` now creates a `stackcoin.Client` singleton lazily from settings, we need to ensure the client is reset between tests so it picks up the patched settings.

**Step 1: Update `configure_luckypot_stk` fixture**

In `test/e2e/conftest.py`, find the `configure_luckypot_stk` fixture and add a call to `stk.reset_client()` after patching settings and in teardown:

```python
@pytest.fixture
def configure_luckypot_stk(stackcoin_server, seed_data):
    """Configure luckypot.stk to point at the test StackCoin server."""
    import luckypot.config as lp_config
    import luckypot.stk as lp_stk

    original_url = lp_config.settings.stackcoin_api_url
    original_token = lp_config.settings.stackcoin_api_token

    lp_config.settings.stackcoin_api_url = stackcoin_server["base_url"]
    lp_config.settings.stackcoin_api_token = seed_data["BOT_TOKEN"]
    lp_stk.reset_client()  # force new client with updated settings

    yield

    lp_config.settings.stackcoin_api_url = original_url
    lp_config.settings.stackcoin_api_token = original_token
    lp_stk.reset_client()  # reset for next test
```

**Step 2: Update E2E pyproject.toml if needed**

Verify `test/e2e/pyproject.toml` still references the stackcoin package correctly. The existing config references `../../tmp/stackcoin-python/stackcoin` which should still be correct.

**Step 3: Commit**

```bash
git add test/e2e/conftest.py
git commit -m "fix: reset stackcoin client between E2E tests"
```

---

## Phase 3: Verify

### Task 10: Run E2E tests

**Step 1: Ensure StackCoin server is ready**

The E2E tests start their own server, but make sure the project compiles first:

```bash
mix compile
```

**Step 2: Install all test dependencies**

From `test/e2e/`:
```bash
uv pip install -e "../../tmp/stackcoin-python/stackcoin"
uv pip install -e "../../tmp/LuckyPot"
uv pip install -e .
```

**Step 3: Run the full E2E suite**

```bash
uv run pytest test/e2e/ -v
```

Expected: All tests pass. The tests exercise:
- StackCoin HTTP API directly (`test_stackcoin_api.py`)
- WebSocket gateway (`test_websocket_gateway.py`)
- LuckyPot game logic against real server (`test_luckypot.py`)

**Step 4: If tests fail, debug and fix**

Common issues:
- Model field names don't match what the server returns -- check generated `models.py` against actual API responses
- Import paths changed -- fix in stk.py or game.py
- Gateway event format mismatch -- check Event model fields vs what Phoenix Channel sends
- Client not reset between tests -- ensure `reset_client()` is called

**Step 5: Final commit**

```bash
git add -A
git commit -m "feat: complete stackcoin SDK migration with passing E2E tests"
```

---

## Summary

| # | Phase | Task | Scope |
|---|-------|------|-------|
| 1 | SDK | Clean old code, set up structure | stackcoin-python |
| 2 | SDK | Generate Pydantic v2 models | stackcoin-python |
| 3 | SDK | Write REST client | stackcoin-python |
| 4 | SDK | Write WebSocket gateway | stackcoin-python |
| 5 | SDK | Install and smoke test | stackcoin-python |
| 6 | Migration | Update LuckyPot deps | LuckyPot |
| 7 | Migration | Rewrite stk.py | LuckyPot |
| 8 | Migration | Swap gateway | LuckyPot |
| 9 | Migration | Fix E2E fixtures | E2E tests |
| 10 | Verify | Run E2E suite | Cross-cutting |

**Dependency order:** Tasks 1-4 are sequential (each builds on the previous). Task 5 verifies 1-4. Tasks 6-9 are sequential (LuckyPot migration). Task 10 verifies everything.
