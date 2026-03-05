# Typed Events Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add typed event schemas to the OpenAPI spec and propagate them through codegen to the Python SDK, so both REST and WebSocket events are fully typed end-to-end.

**Architecture:** Add 4 event data schemas + 4 event wrapper schemas + a discriminated union + list response to `schemas.ex`, annotate the `EventController` with an OpenApiSpex operation, regenerate `openapi.json`, regenerate Python models, then update `client.py` and `gateway.py` to use the generated types. Update LuckyPot handlers to use typed event data.

**Tech Stack:** Elixir/OpenApiSpex (server), datamodel-codegen (codegen), Pydantic v2 (SDK), pytest (E2E)

---

### Task 1: Add event schemas to `schemas.ex`

**Files:**
- Modify: `lib/stackcoin_web/schemas.ex` (append before `ErrorResponse` module at line 617)

**Step 1: Add the event data and wrapper schemas**

Add these modules to `schemas.ex` before the `ErrorResponse` module:

```elixir
defmodule TransferCompletedData do
  OpenApiSpex.schema(%{
    title: "TransferCompletedData",
    description: "Data payload for transfer.completed events",
    type: :object,
    properties: %{
      transaction_id: %Schema{type: :integer, description: "Transaction ID"},
      from_id: %Schema{type: :integer, description: "Sender user ID"},
      to_id: %Schema{type: :integer, description: "Recipient user ID"},
      amount: %Schema{type: :integer, description: "Amount transferred"},
      role: %Schema{type: :string, description: "Role of the event recipient (sender or receiver)"}
    },
    required: [:transaction_id, :from_id, :to_id, :amount, :role]
  })
end

defmodule RequestCreatedData do
  OpenApiSpex.schema(%{
    title: "RequestCreatedData",
    description: "Data payload for request.created events",
    type: :object,
    properties: %{
      request_id: %Schema{type: :integer, description: "Request ID"},
      requester_id: %Schema{type: :integer, description: "Requester user ID"},
      responder_id: %Schema{type: :integer, description: "Responder user ID"},
      amount: %Schema{type: :integer, description: "Requested amount"},
      label: %Schema{type: :string, description: "Request label", nullable: true}
    },
    required: [:request_id, :requester_id, :responder_id, :amount]
  })
end

defmodule RequestAcceptedData do
  OpenApiSpex.schema(%{
    title: "RequestAcceptedData",
    description: "Data payload for request.accepted events",
    type: :object,
    properties: %{
      request_id: %Schema{type: :integer, description: "Request ID"},
      status: %Schema{type: :string, description: "New request status"},
      transaction_id: %Schema{type: :integer, description: "Created transaction ID"},
      amount: %Schema{type: :integer, description: "Request amount"}
    },
    required: [:request_id, :status, :transaction_id, :amount]
  })
end

defmodule RequestDeniedData do
  OpenApiSpex.schema(%{
    title: "RequestDeniedData",
    description: "Data payload for request.denied events",
    type: :object,
    properties: %{
      request_id: %Schema{type: :integer, description: "Request ID"},
      status: %Schema{type: :string, description: "New request status"}
    },
    required: [:request_id, :status]
  })
end

defmodule TransferCompletedEvent do
  OpenApiSpex.schema(%{
    title: "TransferCompletedEvent",
    description: "A transfer.completed event",
    type: :object,
    properties: %{
      id: %Schema{type: :integer, description: "Event ID"},
      type: %Schema{type: :string, description: "Event type", enum: ["transfer.completed"]},
      data: TransferCompletedData,
      inserted_at: %Schema{type: :string, description: "Event timestamp", format: :"date-time"}
    },
    required: [:id, :type, :data, :inserted_at]
  })
end

defmodule RequestCreatedEvent do
  OpenApiSpex.schema(%{
    title: "RequestCreatedEvent",
    description: "A request.created event",
    type: :object,
    properties: %{
      id: %Schema{type: :integer, description: "Event ID"},
      type: %Schema{type: :string, description: "Event type", enum: ["request.created"]},
      data: RequestCreatedData,
      inserted_at: %Schema{type: :string, description: "Event timestamp", format: :"date-time"}
    },
    required: [:id, :type, :data, :inserted_at]
  })
end

defmodule RequestAcceptedEvent do
  OpenApiSpex.schema(%{
    title: "RequestAcceptedEvent",
    description: "A request.accepted event",
    type: :object,
    properties: %{
      id: %Schema{type: :integer, description: "Event ID"},
      type: %Schema{type: :string, description: "Event type", enum: ["request.accepted"]},
      data: RequestAcceptedData,
      inserted_at: %Schema{type: :string, description: "Event timestamp", format: :"date-time"}
    },
    required: [:id, :type, :data, :inserted_at]
  })
end

defmodule RequestDeniedEvent do
  OpenApiSpex.schema(%{
    title: "RequestDeniedEvent",
    description: "A request.denied event",
    type: :object,
    properties: %{
      id: %Schema{type: :integer, description: "Event ID"},
      type: %Schema{type: :string, description: "Event type", enum: ["request.denied"]},
      data: RequestDeniedData,
      inserted_at: %Schema{type: :string, description: "Event timestamp", format: :"date-time"}
    },
    required: [:id, :type, :data, :inserted_at]
  })
end

defmodule Event do
  OpenApiSpex.schema(%{
    title: "Event",
    description: "A StackCoin event (discriminated by type)",
    oneOf: [
      TransferCompletedEvent,
      RequestCreatedEvent,
      RequestAcceptedEvent,
      RequestDeniedEvent
    ],
    discriminator: %OpenApiSpex.Discriminator{
      propertyName: "type",
      mapping: %{
        "transfer.completed" => "#/components/schemas/TransferCompletedEvent",
        "request.created" => "#/components/schemas/RequestCreatedEvent",
        "request.accepted" => "#/components/schemas/RequestAcceptedEvent",
        "request.denied" => "#/components/schemas/RequestDeniedEvent"
      }
    }
  })
end

defmodule EventsResponse do
  OpenApiSpex.schema(%{
    title: "EventsResponse",
    description: "Response schema for listing events",
    type: :object,
    properties: %{
      events: %Schema{description: "The events list", type: :array, items: Event}
    },
    required: [:events]
  })
end
```

**Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compiles successfully

---

### Task 2: Add OpenApiSpex operation to EventController

**Files:**
- Modify: `lib/stackcoin_web/controllers/event_controller.ex`

**Step 1: Add the operation spec**

Replace the full file content with:

```elixir
defmodule StackCoinWeb.EventController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StackCoin.Core.Event

  operation :index,
    operation_id: "stackcoin_events",
    summary: "Get events for the authenticated user",
    description: "Returns events since the given ID, ordered by ID ascending. Used for polling and cursor-based pagination.",
    parameters: [
      since_id: [in: :query, description: "Return events with ID greater than this value", type: :integer, example: 0, required: false]
    ],
    responses: [
      ok: {"Events response", "application/json", StackCoinWeb.Schemas.EventsResponse}
    ]

  def index(conn, params) do
    user = conn.assigns.current_user
    since_id = parse_since_id(params)

    events =
      Event.list_events_since(user.id, since_id)
      |> Enum.map(&Event.serialize_event/1)

    json(conn, %{events: events})
  end

  defp parse_since_id(%{"since_id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp parse_since_id(_), do: 0
end
```

**Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compiles successfully

---

### Task 3: Regenerate openapi.json

**Step 1: Generate the spec**

Run: `just openapi`
Expected: `openapi.json` is updated with Event schemas and the `/api/events` path

**Step 2: Verify the new schemas exist in the output**

Run: `cat openapi.json | jq '.components.schemas | keys[]' | grep -i event`
Expected: Should list TransferCompletedData, TransferCompletedEvent, RequestCreatedData, RequestCreatedEvent, RequestAcceptedData, RequestAcceptedEvent, RequestDeniedData, RequestDeniedEvent, Event, EventsResponse

**Step 3: Verify the events path exists**

Run: `cat openapi.json | jq '.paths["/api/events"]'`
Expected: Should show the GET operation with EventsResponse

---

### Task 4: Regenerate Python models

**Step 1: Run datamodel-codegen**

Run (from `tmp/stackcoin-python`): `STACKCOIN_ROOT=../.. just generate`
Expected: `stackcoin/stackcoin/models.py` is regenerated with event model classes

**Step 2: Verify generated event models exist**

Check that models.py contains classes like `TransferCompletedData`, `TransferCompletedEvent`, `RequestAcceptedData`, etc.

Note: `datamodel-codegen` may or may not generate a proper discriminated union type alias for the `Event` oneOf. If it doesn't generate a usable `Event` union type, we'll need to hand-write it in `__init__.py` or a separate file. Assess after generation.

---

### Task 5: Update SDK `client.py` to use typed Event models

**Files:**
- Modify: `tmp/stackcoin-python/stackcoin/stackcoin/client.py`

**Step 1: Update imports to include the generated event/response models**

Add the generated `EventsResponse` (and individual event types if available) to the imports.

**Step 2: Update `get_events()` return type**

Change from:
```python
async def get_events(self, *, since_id: int = 0) -> list[dict[str, Any]]:
```

To return typed events. The exact return type depends on what datamodel-codegen generates — it could be `list[Event]` (a union) or `list[TransferCompletedEvent | RequestCreatedEvent | ...]`. Use the generated `EventsResponse` wrapper to parse.

```python
async def get_events(self, *, since_id: int = 0) -> list[...]:
    params: dict[str, Any] = {}
    if since_id:
        params["since_id"] = since_id
    resp = await self._http.get("/api/events", params=params)
    self._raise_for_error(resp)
    wrapper = EventsResponse.model_validate(resp.json())
    return wrapper.events or []
```

---

### Task 6: Update SDK `gateway.py` to use generated Event types

**Files:**
- Modify: `tmp/stackcoin-python/stackcoin/stackcoin/gateway.py`

**Step 1: Remove the hand-rolled `Event` class**

Delete the `Event` class (lines 13-19) and import the generated event types from `models.py` instead.

**Step 2: Update `_handle_message` to parse into typed events**

The gateway receives events with the same shape as the REST API. Use the discriminated union to parse:

```python
from .models import (
    TransferCompletedEvent,
    RequestCreatedEvent,
    RequestAcceptedEvent,
    RequestDeniedEvent,
    # ... whatever Event union type is generated
)
```

Parse the payload with the appropriate model. The `type` field determines which model to use.

**Step 3: Update handler dispatch**

Handlers should receive the specific typed event. The `EventHandler` type alias needs updating to accept the generated event types.

---

### Task 7: Update SDK `__init__.py` exports

**Files:**
- Modify: `tmp/stackcoin-python/stackcoin/stackcoin/__init__.py`

Export the new event types so users can import them as `stackcoin.TransferCompletedEvent`, `stackcoin.Event`, etc.

---

### Task 8: Update LuckyPot to use typed events

**Files:**
- Modify: `tmp/LuckyPot/lucky_pot.py` (handler type hints)
- Modify: `tmp/LuckyPot/luckypot/game.py` (event parameter types)

**Step 1: Update `lucky_pot.py` handlers**

Change handlers from `stackcoin.Event` to the specific typed event:
```python
async def handle_accepted(event: stackcoin.RequestAcceptedEvent):
    await on_request_accepted(event.data, announce=announce)
```

**Step 2: Update `game.py` event handlers**

Change `on_request_accepted` and `on_request_denied` from accepting `dict` to accepting the typed data models:
```python
async def on_request_accepted(event_data: stackcoin.RequestAcceptedData, ...):
    request_id = str(event_data.request_id)
```

This eliminates the `event.get("request_id", "")` dict access pattern.

---

### Task 9: Run E2E tests

**Step 1: Start the server** (if not running)

**Step 2: Run all tests**

Run (from `test/e2e`): `uv run pytest -v`
Expected: 47/47 tests pass

---

### Task 10: Update examples

**Files:**
- Modify: `tmp/stackcoin-python/examples/simple_cli.py`

Update the event handlers in `simple_cli.py` to use the typed event models instead of `event.data["amount"]` dict access.
