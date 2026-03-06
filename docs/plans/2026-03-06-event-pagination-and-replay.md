# Event Pagination & WebSocket Replay Limits

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `has_more` cursor pagination to the REST events endpoint, enforce a replay limit on the WebSocket gateway (rejecting joins that request too many missed events), and update the Python library to support auto-pagination and handle gateway rejection.

**Architecture:** The REST endpoint queries `limit + 1` rows and returns `limit` rows plus a `has_more` boolean. The WebSocket gateway counts missed events before replaying; if the count exceeds the replay limit, it rejects the join with a structured error directing the bot to catch up via REST. The Python library's `get_events()` gains an `auto_paginate` mode, and the Gateway handles join rejection gracefully.

**Tech Stack:** Elixir (Phoenix channels, Ecto), Python (httpx, websockets, Pydantic)

---

### Task 1: Add `has_more` to the REST events endpoint

**Files:**
- Modify: `lib/stackcoin/core/event.ex:39-45`
- Modify: `lib/stackcoin_web/controllers/event_controller.ex:25-34`

**Step 1: Update `list_events_since` to return `{events, has_more}`**

In `lib/stackcoin/core/event.ex`, change `list_events_since/2` to fetch `limit + 1` rows, return at most `limit`, and report whether more exist:

```elixir
@events_page_size 100

def list_events_since(user_id, last_event_id) do
  rows =
    Event
    |> where([e], e.user_id == ^user_id and e.id > ^last_event_id)
    |> order_by([e], asc: e.id)
    |> limit(^(@events_page_size + 1))
    |> Repo.all()

  has_more = length(rows) > @events_page_size
  events = Enum.take(rows, @events_page_size)
  {events, has_more}
end
```

**Step 2: Add `count_events_since/2` for the WebSocket gateway**

Also in `lib/stackcoin/core/event.ex`, add a count function (used by Task 3):

```elixir
def count_events_since(user_id, last_event_id) do
  Event
  |> where([e], e.user_id == ^user_id and e.id > ^last_event_id)
  |> Repo.aggregate(:count)
end
```

**Step 3: Update the controller to return `has_more`**

In `lib/stackcoin_web/controllers/event_controller.ex`, update `index/2`:

```elixir
def index(conn, params) do
  user = conn.assigns.current_user
  since_id = parse_since_id(params)

  {events, has_more} = Event.list_events_since(user.id, since_id)

  json(conn, %{
    events: Enum.map(events, &Event.serialize_event/1),
    has_more: has_more
  })
end
```

**Step 4: Update the `EventsResponse` OpenApiSpex schema**

In `lib/stackcoin/event_schema.ex`, update the `EventsResponse` schema generated in `__before_compile__` to include `has_more`:

```elixir
defmodule unquote(events_response_module) do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "EventsResponse",
    description: "Response schema for listing events",
    type: :object,
    properties: %{
      events: %OpenApiSpex.Schema{
        description: "The events list",
        type: :array,
        items: unquote(event_module)
      },
      has_more: %OpenApiSpex.Schema{
        description: "Whether more events exist beyond this page",
        type: :boolean
      }
    },
    required: [:events, :has_more]
  })
end
```

**Step 5: Compile**

Run: `mix compile --warnings-as-errors`

**Step 6: Update all callers of `list_events_since` to destructure tuple**

The following callers need updating (they currently expect a plain list):

- `lib/stackcoin_web/channels/bot_channel.ex:27` — `events = Event.list_events_since(...)` → `{events, _has_more} = Event.list_events_since(...)`
- Any test files that call `Event.list_events_since` directly:
  - `test/stackcoin/core/event_test.exs` (2 calls)
  - `test/stackcoin/core/event_integration_test.exs` (8 calls)
  - `test/stackcoin_web/controllers/event_controller_test.exs` (1 call)

**Step 7: Compile and run existing tests**

Run: `mix compile --warnings-as-errors && mix test`
Expected: All 223 tests pass.

**Step 8: Commit**

```
feat: add has_more cursor pagination to events REST endpoint
```

---

### Task 2: Add tests for REST events pagination

**Files:**
- Modify: `test/stackcoin/core/event_test.exs`
- Modify: `test/stackcoin_web/controllers/event_controller_test.exs`

**Step 1: Add unit test for `has_more` behavior**

In `test/stackcoin/core/event_test.exs`, add a test in the `list_events_since/2` describe block:

```elixir
test "returns has_more=false when events fit in one page", %{user1: user1, user2: user2} do
  {:ok, _} =
    Event.create_event("request.denied", user1.id, %{
      request_id: 1,
      status: "denied"
    })

  {events, has_more} = Event.list_events_since(user1.id, 0)
  assert length(events) == 1
  refute has_more
end
```

**Step 2: Add controller test for `has_more` in response**

In `test/stackcoin_web/controllers/event_controller_test.exs`, add:

```elixir
test "response includes has_more field", %{
  conn: conn,
  bot: bot,
  bot_token: bot_token,
  recipient: recipient
} do
  {:ok, _txn} = Bank.transfer_between_users(bot.user.id, recipient.id, 10, "test")

  conn =
    conn
    |> put_req_header("authorization", "Bearer #{bot_token}")
    |> get(~p"/api/events")

  response = json_response(conn, 200)
  assert is_boolean(response["has_more"])
  assert response["has_more"] == false
end
```

**Step 3: Run tests**

Run: `mix test test/stackcoin/core/event_test.exs test/stackcoin_web/controllers/event_controller_test.exs --trace`
Expected: All pass.

**Step 4: Commit**

```
test: add pagination tests for events endpoint
```

---

### Task 3: Reject WebSocket joins with too many missed events

**Files:**
- Modify: `lib/stackcoin_web/channels/bot_channel.ex`

**Step 1: Add replay limit check to `join/3`**

Replace the current join logic with a count check before subscribing:

```elixir
@replay_limit 100

@impl true
def join("user:" <> user_id_str, payload, socket) do
  user_id =
    case user_id_str do
      "self" -> socket.assigns.user.id
      id_str -> String.to_integer(id_str)
    end

  if user_id == socket.assigns.user.id do
    last_event_id = Map.get(payload, "last_event_id", 0)
    missed_count = Event.count_events_since(user_id, last_event_id)

    if missed_count > @replay_limit do
      {:error,
       %{
         reason: "too_many_missed_events",
         missed_count: missed_count,
         replay_limit: @replay_limit,
         message: "Use GET /api/events?since_id=#{last_event_id} to catch up, then reconnect with a recent last_event_id"
       }}
    else
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "user:#{user_id}")
      send(self(), {:replay_events, last_event_id})
      {:ok, socket}
    end
  else
    {:error, %{reason: "unauthorized"}}
  end
end
```

**Step 2: Update `handle_info({:replay_events, ...})` to destructure tuple**

```elixir
@impl true
def handle_info({:replay_events, last_event_id}, socket) do
  {events, _has_more} = Event.list_events_since(socket.assigns.user.id, last_event_id)

  for event <- events do
    push(socket, "event", Event.serialize_event(event))
  end

  {:noreply, socket}
end
```

**Step 3: Compile**

Run: `mix compile --warnings-as-errors`

**Step 4: Commit**

```
feat: reject WebSocket joins when too many events are missed
```

---

### Task 4: Add tests for WebSocket replay limit

**Files:**
- Modify: `test/stackcoin_web/channels/bot_channel_test.exs`

**Step 1: Add test for rejection when too many events are missed**

This test creates >100 events by doing many small transfers, then attempts to join with `last_event_id: 0`:

```elixir
test "rejects join when too many events are missed", %{
  bot: bot,
  bot_token: bot_token,
  recipient: recipient
} do
  # Create > 100 events. Each transfer creates 2 events (one for sender, one for receiver).
  # So 51 transfers = 102 events for bot.user.id (51 as sender).
  # Actually each transfer creates 1 event per user, so we need 101 transfers to get 101 events for the bot.
  for _ <- 1..101 do
    Event.create_event("transfer.completed", bot.user.id, %{
      transaction_id: 1,
      from_id: bot.user.id,
      to_id: recipient.id,
      amount: 1,
      role: "sender"
    })
  end

  {:ok, socket} =
    Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

  assert {:error, %{reason: "too_many_missed_events"} = error} =
           Phoenix.ChannelTest.join(socket, "user:#{bot.user.id}", %{"last_event_id" => 0})

  assert error.missed_count == 101
  assert error.replay_limit == 100
end
```

**Step 2: Add test for successful join at the boundary**

```elixir
test "allows join when missed events are at the replay limit", %{
  bot: bot,
  bot_token: bot_token,
  recipient: recipient
} do
  for _ <- 1..100 do
    Event.create_event("transfer.completed", bot.user.id, %{
      transaction_id: 1,
      from_id: bot.user.id,
      to_id: recipient.id,
      amount: 1,
      role: "sender"
    })
  end

  {:ok, socket} =
    Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

  assert {:ok, _reply, _socket} =
           Phoenix.ChannelTest.join(socket, "user:#{bot.user.id}", %{"last_event_id" => 0})
end
```

Note: The test must add `alias StackCoin.Core.Event` to the aliases at the top of the test module.

**Step 3: Run channel tests**

Run: `mix test test/stackcoin_web/channels/bot_channel_test.exs --trace`
Expected: All pass.

**Step 4: Commit**

```
test: add WebSocket replay limit boundary tests
```

---

### Task 5: Regenerate OpenAPI spec and Python models

**Files:**
- Regenerate: `openapi.json`
- Regenerate: `tmp/stackcoin-python/stackcoin/stackcoin/models.py`

**Step 1: Regenerate the OpenAPI spec**

Run: `just openapi`

**Step 2: Verify `has_more` appears in the spec**

Check that the `EventsResponse` schema in `openapi.json` now includes `has_more`.

**Step 3: Regenerate Python models**

Run (from `tmp/stackcoin-python`): `STACKCOIN_ROOT=/Users/jack/repos/personal/StackCoin just generate`

**Step 4: Verify `EventsResponse` model has `has_more` field**

Check that `models.py` `EventsResponse` class now includes `has_more: bool`.

**Step 5: Commit both repos**

```
chore: regenerate openapi.json and Python models with has_more field
```

---

### Task 6: Update Python library client for auto-pagination

**Files:**
- Modify: `tmp/stackcoin-python/stackcoin/stackcoin/client.py:195-203`

**Step 1: Update `get_events` to support auto-pagination**

Replace the current `get_events` method:

```python
async def get_events(self, *, since_id: int = 0) -> list[AnyEvent]:
    """Return typed events since the given ID.

    Automatically paginates through all available events.
    """
    all_events: list[AnyEvent] = []
    cursor = since_id

    while True:
        params: dict[str, Any] = {}
        if cursor:
            params["since_id"] = cursor
        resp = await self._http.get("/api/events", params=params)
        self._raise_for_error(resp)
        wrapper = EventsResponse.model_validate(resp.json())
        page = [e.root for e in wrapper.events]
        all_events.extend(page)

        if not wrapper.has_more or not page:
            break
        cursor = page[-1].id

    return all_events
```

**Step 2: Commit**

```
feat: auto-paginate get_events in Python library
```

---

### Task 7: Update Python Gateway to handle join rejection

**Files:**
- Modify: `tmp/stackcoin-python/stackcoin/stackcoin/gateway.py:90-106`
- Modify: `tmp/stackcoin-python/stackcoin/stackcoin/errors.py`

**Step 1: Add `TooManyMissedEventsError` exception**

In `errors.py`, add:

```python
class TooManyMissedEventsError(StackCoinError):
    """Raised when the WebSocket gateway rejects a join due to too many missed events."""

    def __init__(self, missed_count: int, replay_limit: int, message: str):
        super().__init__(status_code=0, error="too_many_missed_events", message=message)
        self.missed_count = missed_count
        self.replay_limit = replay_limit
```

**Step 2: Update `_join_channel` to detect rejection**

In `gateway.py`, update `_join_channel`:

```python
async def _join_channel(self, ws: Any) -> None:
    """Join the user:self channel with event replay."""
    from .errors import TooManyMissedEventsError

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
    if reply[3] == "phx_reply" and reply[4].get("status") == "ok":
        return

    # Check for too_many_missed_events rejection
    response = reply[4].get("response", {})
    if response.get("reason") == "too_many_missed_events":
        raise TooManyMissedEventsError(
            missed_count=response.get("missed_count", 0),
            replay_limit=response.get("replay_limit", 0),
            message=response.get("message", "Too many missed events"),
        )

    raise ConnectionError(f"Failed to join channel: {reply}")
```

**Step 3: Update `connect` to NOT auto-retry on `TooManyMissedEventsError`**

In `gateway.py`, update the `connect` method's exception handler:

```python
async def connect(self) -> None:
    """Connect and listen for events. Reconnects automatically on failure."""
    import websockets

    from .errors import TooManyMissedEventsError

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

        except TooManyMissedEventsError:
            raise  # Don't retry — caller must catch up via REST
        except Exception:
            if self._running:
                await asyncio.sleep(5)
```

**Step 4: Export the new error from `__init__.py`**

Add `TooManyMissedEventsError` to the imports and `__all__` in `tmp/stackcoin-python/stackcoin/stackcoin/__init__.py`.

**Step 5: Commit**

```
feat: handle WebSocket join rejection in Python Gateway
```

---

### Task 8: Run full test suite

**Step 1: Run Elixir tests**

Run: `mix test`
Expected: All pass (should be ~227 with new tests).

**Step 2: Run E2E tests**

Run (from `test/e2e`): `uv run pytest -x -v`
Expected: 47/47 pass.

**Step 3: Commit if any fixups needed, otherwise done**

---

### Task 9: Add E2E test for pagination boundary

**Files:**
- Modify: `test/e2e/test_stackcoin_api.py`

**Step 1: Add test that exercises `has_more`**

This test creates >100 events and verifies the client auto-paginates:

```python
class TestEventPagination:
    """Test event pagination with has_more."""

    async def test_has_more_false_with_few_events(self, test_context, auth_headers):
        """Events response includes has_more=false when all events fit in one page."""
        base_url = test_context["base_url"]

        async with httpx.AsyncClient(base_url=base_url, headers=auth_headers) as http:
            resp = await http.get("/api/events")
            assert resp.status_code == 200
            body = resp.json()
            assert "has_more" in body
            assert body["has_more"] is False
```

**Step 2: Run E2E tests**

Run: `uv run pytest -x -v`
Expected: 48/48 pass.

**Step 3: Final commit**

```
test: add E2E test for event pagination has_more field
```
