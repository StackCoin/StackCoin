# Event System, WebSocket Gateway, Idempotency Keys & E2E Testing

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace polling-based bot communication with a real-time event system, add idempotency for safe retries, fix known race conditions, and build end-to-end tests that launch both StackCoin and LuckyPot to validate the full flow.

**Architecture:** Events are first-class persisted resources in StackCoin, keyed by `user_id` (not bot-specific). Every state change relevant to a user (request accepted/denied, transfer completed) produces an Event row. This means any user -- bot or human -- can have events tracked, enabling future features like web dashboards and notification feeds. Events are delivered in real-time via Phoenix Channels (WebSocket) and also queryable via REST as a fallback. Idempotency keys prevent duplicate mutations. E2E tests spin up a real StackCoin test server and exercise LuckyPot's logic against it over HTTP.

**Tech Stack:** Elixir/Phoenix (Channels, PubSub), Ecto/SQLite3, Python (httpx, websockets), pytest, ExUnit

---

## Phase 1: Event System (StackCoin Server)

### Task 1: Create events migration and schema

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_create_events.exs`
- Create: `lib/stackcoin/schema/event.ex`

**Step 1: Write the migration**

```elixir
defmodule StackCoin.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :type, :string, null: false
      add :user_id, references(:user, type: :integer), null: true
      add :data, :text, null: false
      add :inserted_at, :naive_datetime, null: false, default: fragment("CURRENT_TIMESTAMP")
    end

    create index(:events, [:user_id])
    create index(:events, [:user_id, :id])
    create index(:events, [:type])
  end
end
```

Notes:
- `user_id` references the `user` table directly -- any user (bot, Discord user, or internal) can have events.
- `user_id` is nullable for system-wide events that don't target a specific user.
- `data` is JSON stored as text (SQLite has no native JSON column).
- The `(user_id, id)` compound index supports "give me events after ID X for user Y" queries efficiently.

**Step 2: Write the schema**

```elixir
defmodule StackCoin.Schema.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "events" do
    field :type, :string
    field :user_id, :integer
    field :data, :string
    field :inserted_at, :naive_datetime
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :user_id, :data])
    |> validate_required([:type, :data])
  end
end
```

**Step 3: Run migration**

Run: `mix ecto.migrate`
Expected: Migration succeeds, events table created.

**Step 4: Commit**

```
git add priv/repo/migrations/*_create_events.exs lib/stackcoin/schema/event.ex
git commit -m "feat: add events table and schema"
```

---

### Task 2: Create Event core module

**Files:**
- Create: `lib/stackcoin/core/event.ex`
- Test: `test/stackcoin/core/event_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule StackCoin.Core.EventTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Event, User}

  describe "create_event/3" do
    setup do
      # Create real users so the FK constraint is satisfied
      {:ok, user1} = User.create_user_account("111", "EventUser1", balance: 0)
      {:ok, user2} = User.create_user_account("222", "EventUser2", balance: 0)
      %{user1: user1, user2: user2}
    end

    test "creates an event with type, user_id, and data", %{user1: user1} do
      {:ok, event} = Event.create_event("request.created", user1.id, %{request_id: 42, amount: 100})

      assert event.type == "request.created"
      assert event.user_id == user1.id
      assert event.id != nil

      decoded = Jason.decode!(event.data)
      assert decoded["request_id"] == 42
      assert decoded["amount"] == 100
    end

    test "creates an event without user_id" do
      {:ok, event} = Event.create_event("transfer.completed", nil, %{transaction_id: 5})

      assert event.type == "transfer.completed"
      assert event.user_id == nil
    end
  end

  describe "list_events_since/2" do
    setup do
      {:ok, user1} = User.create_user_account("333", "EventListUser1", balance: 0)
      {:ok, user2} = User.create_user_account("444", "EventListUser2", balance: 0)
      %{user1: user1, user2: user2}
    end

    test "returns events after a given ID for a specific user", %{user1: user1, user2: user2} do
      {:ok, e1} = Event.create_event("request.created", user1.id, %{request_id: 1})
      {:ok, e2} = Event.create_event("request.accepted", user1.id, %{request_id: 1})
      {:ok, _e3} = Event.create_event("request.created", user2.id, %{request_id: 2})

      events = Event.list_events_since(user1.id, e1.id)
      assert length(events) == 1
      assert hd(events).id == e2.id
    end

    test "returns all events for user when last_event_id is 0", %{user1: user1} do
      {:ok, _e1} = Event.create_event("request.created", user1.id, %{request_id: 1})
      {:ok, _e2} = Event.create_event("request.accepted", user1.id, %{request_id: 1})

      events = Event.list_events_since(user1.id, 0)
      assert length(events) == 2
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/stackcoin/core/event_test.exs`
Expected: FAIL (module not found)

**Step 3: Write implementation**

```elixir
defmodule StackCoin.Core.Event do
  alias StackCoin.Repo
  alias StackCoin.Schema.Event
  import Ecto.Query

  @doc """
  Create a new event. Data is a map that will be JSON-encoded.
  Broadcasts to PubSub topic "user:<user_id>" if user_id is present.
  """
  def create_event(type, user_id, data) when is_binary(type) and is_map(data) do
    attrs = %{
      type: type,
      user_id: user_id,
      data: Jason.encode!(data)
    }

    result =
      %Event{}
      |> Event.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, event} ->
        if user_id do
          Phoenix.PubSub.broadcast(
            StackCoin.PubSub,
            "user:#{user_id}",
            {:event, serialize_event(event)}
          )
        end

        {:ok, event}

      error ->
        error
    end
  end

  @doc """
  List events for a user since a given event ID.
  Used for replaying missed events on WebSocket reconnect.
  """
  def list_events_since(user_id, last_event_id) do
    Event
    |> where([e], e.user_id == ^user_id and e.id > ^last_event_id)
    |> order_by([e], asc: e.id)
    |> limit(100)
    |> Repo.all()
  end

  @doc """
  Serialize an event for transmission over WebSocket or REST.
  """
  def serialize_event(%Event{} = event) do
    %{
      id: event.id,
      type: event.type,
      data: Jason.decode!(event.data),
      inserted_at: NaiveDateTime.to_iso8601(event.inserted_at)
    }
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/stackcoin/core/event_test.exs`
Expected: PASS

**Step 5: Commit**

```
git add lib/stackcoin/core/event.ex test/stackcoin/core/event_test.exs
git commit -m "feat: add Event core module with create and list_since"
```

---

### Task 3: Emit events from Bank and Request modules

**Files:**
- Modify: `lib/stackcoin/core/bank.ex` (inside `create_transaction`)
- Modify: `lib/stackcoin/core/request.ex` (inside `create_request`, `accept_request`, `deny_request`)
- Test: `test/stackcoin/core/event_integration_test.exs`

**Step 1: Write integration test**

```elixir
defmodule StackCoin.Core.EventIntegrationTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve, Request, Event}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{owner: owner, bot: bot, recipient: recipient}
  end

  test "transfer emits transfer.completed event for both users", %{bot: bot, recipient: recipient} do
    {:ok, _txn} = Bank.transfer_between_users(bot.user.id, recipient.id, 50, "test")

    # Event for the sender (bot's user_id)
    sender_events = Event.list_events_since(bot.user.id, 0)
    transfer_events = Enum.filter(sender_events, &(&1.type == "transfer.completed"))
    assert length(transfer_events) >= 1

    event = List.last(transfer_events)
    data = Jason.decode!(event.data)
    assert data["amount"] == 50
    assert data["to_id"] == recipient.id

    # Event for the receiver too
    receiver_events = Event.list_events_since(recipient.id, 0)
    receiver_transfer_events = Enum.filter(receiver_events, &(&1.type == "transfer.completed"))
    assert length(receiver_transfer_events) >= 1
  end

  test "create_request emits request.created event for both parties", %{bot: bot, recipient: recipient} do
    {:ok, request} = Request.create_request(bot.user.id, recipient.id, 75, "test request")

    # Event for the requester (bot's user)
    requester_events = Event.list_events_since(bot.user.id, 0)
    created_events = Enum.filter(requester_events, &(&1.type == "request.created"))
    assert length(created_events) >= 1

    data = Jason.decode!(List.last(created_events).data)
    assert data["request_id"] == request.id
    assert data["amount"] == 75

    # Event for the responder too
    responder_events = Event.list_events_since(recipient.id, 0)
    responder_created = Enum.filter(responder_events, &(&1.type == "request.created"))
    assert length(responder_created) >= 1
  end

  test "accept_request emits request.accepted event for both parties", %{bot: bot, recipient: recipient} do
    {:ok, request} = Request.create_request(recipient.id, bot.user.id, 50, "accept test")
    {:ok, _accepted} = Request.accept_request(request.id, bot.user.id)

    # Event for the responder (bot's user)
    responder_events = Event.list_events_since(bot.user.id, 0)
    accepted_events = Enum.filter(responder_events, &(&1.type == "request.accepted"))
    assert length(accepted_events) >= 1

    data = Jason.decode!(List.last(accepted_events).data)
    assert data["request_id"] == request.id
    assert data["status"] == "accepted"

    # Event for the requester too
    requester_events = Event.list_events_since(recipient.id, 0)
    requester_accepted = Enum.filter(requester_events, &(&1.type == "request.accepted"))
    assert length(requester_accepted) >= 1
  end

  test "deny_request emits request.denied event for both parties", %{bot: bot, recipient: recipient} do
    {:ok, request} = Request.create_request(recipient.id, bot.user.id, 30, "deny test")
    {:ok, _denied} = Request.deny_request(request.id, bot.user.id)

    # Event for the responder (bot's user)
    responder_events = Event.list_events_since(bot.user.id, 0)
    denied_events = Enum.filter(responder_events, &(&1.type == "request.denied"))
    assert length(denied_events) >= 1

    data = Jason.decode!(List.last(denied_events).data)
    assert data["request_id"] == request.id
    assert data["status"] == "denied"

    # Event for the requester too
    requester_events = Event.list_events_since(recipient.id, 0)
    requester_denied = Enum.filter(requester_events, &(&1.type == "request.denied"))
    assert length(requester_denied) >= 1
  end
end
```

**Step 2: Run to verify it fails**

Run: `mix test test/stackcoin/core/event_integration_test.exs`
Expected: FAIL (no events emitted yet)

**Step 3: Modify bank.ex**

In `lib/stackcoin/core/bank.ex`, inside the `create_transaction` function, after the successful transaction insert and balance updates, add event emission. The key change: we need to determine if the sender or receiver is a bot, and if so, emit an event targeted at that bot.

At the end of `transfer_between_users`, after the successful `Repo.transaction`, emit events for both users involved:

```elixir
case result do
  {:ok, transaction} ->
    # Emit events for both users involved in the transfer
    for {user_id, role} <- [{from_user_id, "sender"}, {to_user_id, "receiver"}] do
      Event.create_event("transfer.completed", user_id, %{
        transaction_id: transaction.id,
        from_id: from_user_id,
        to_id: to_user_id,
        amount: transaction.amount,
        role: role
      })
    end
    {:ok, transaction}

  error -> error
end
```

Note: Events are emitted for every user, not just bots. The PubSub broadcast in `Event.create_event` will only be received if someone (a WebSocket channel, a LiveView, etc.) is subscribed to `"user:<user_id>"`. If nobody is listening, the broadcast is a no-op.

**Step 4: Modify request.ex**

Similarly, in `create_request`, `accept_request`, and `deny_request`, emit events after the successful database operation. Events are emitted for both the requester and responder user_ids.

For `create_request`:
```elixir
# After successful insert, emit event for both parties
for user_id <- [requester_id, responder_id] do
  Event.create_event("request.created", user_id, %{
    request_id: request.id,
    requester_id: requester_id,
    responder_id: responder_id,
    amount: amount,
    label: label
  })
end
```

For `accept_request`:
```elixir
# After successful accept, emit event for both parties
for user_id <- [request.requester_id, request.responder_id] do
  Event.create_event("request.accepted", user_id, %{
    request_id: request.id,
    status: "accepted",
    transaction_id: transaction.id,
    amount: request.amount
  })
end
```

For `deny_request`:
```elixir
for user_id <- [request.requester_id, request.responder_id] do
  Event.create_event("request.denied", user_id, %{
    request_id: request.id,
    status: "denied"
  })
end
```

**Step 5: Run tests**

Run: `mix test test/stackcoin/core/event_integration_test.exs`
Expected: PASS

**Step 6: Run full test suite**

Run: `mix test`
Expected: All existing tests still pass.

**Step 7: Commit**

```
git add lib/stackcoin/core/bank.ex lib/stackcoin/core/request.ex test/stackcoin/core/event_integration_test.exs
git commit -m "feat: emit events from Bank and Request modules"
```

---

### Task 4: Add REST endpoint for events

**Files:**
- Create: `lib/stackcoin_web/controllers/event_controller.ex`
- Modify: `lib/stackcoin_web/router.ex`
- Test: `test/stackcoin_web/controllers/event_controller_test.exs`

**Step 1: Write the test**

```elixir
defmodule StackCoinWebTest.EventControllerTest do
  use StackCoinWeb.ConnCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve, Event}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{bot: bot, recipient: recipient, bot_token: bot.token}
  end

  describe "GET /api/events" do
    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, ~p"/api/events")
      assert json_response(conn, 401)
    end

    test "returns events for authenticated user (bot)", %{conn: conn, bot: bot, bot_token: bot_token, recipient: recipient} do
      # Create some events by performing actions
      {:ok, _txn} = Bank.transfer_between_users(bot.user.id, recipient.id, 10, "test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/events")

      response = json_response(conn, 200)
      assert is_list(response["events"])
      assert length(response["events"]) >= 1

      event = hd(response["events"])
      assert Map.has_key?(event, "id")
      assert Map.has_key?(event, "type")
      assert Map.has_key?(event, "data")
      assert Map.has_key?(event, "inserted_at")
    end

    test "filters events with since_id parameter", %{conn: conn, bot: bot, bot_token: bot_token, recipient: recipient} do
      {:ok, _txn1} = Bank.transfer_between_users(bot.user.id, recipient.id, 5, "first")
      {:ok, _txn2} = Bank.transfer_between_users(bot.user.id, recipient.id, 5, "second")

      events = Event.list_events_since(bot.user.id, 0)
      first_id = hd(events).id

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/events?since_id=#{first_id}")

      response = json_response(conn, 200)
      assert Enum.all?(response["events"], fn e -> e["id"] > first_id end)
    end
  end
end
```

**Step 2: Run to verify it fails**

Run: `mix test test/stackcoin_web/controllers/event_controller_test.exs`
Expected: FAIL

**Step 3: Implement controller**

```elixir
defmodule StackCoinWeb.EventController do
  use StackCoinWeb, :controller

  alias StackCoin.Core.Event

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

**Step 4: Add route to router.ex**

In the existing `/api` scope (authenticated), add:

```elixir
get "/events", EventController, :index
```

**Step 5: Run tests**

Run: `mix test test/stackcoin_web/controllers/event_controller_test.exs`
Expected: PASS

**Step 6: Run full suite**

Run: `mix test`
Expected: All pass

**Step 7: Commit**

```
git add lib/stackcoin_web/controllers/event_controller.ex lib/stackcoin_web/router.ex test/stackcoin_web/controllers/event_controller_test.exs
git commit -m "feat: add REST endpoint for querying bot events"
```

---

## Phase 2: WebSocket Gateway

### Task 5: Create BotSocket and BotChannel

**Files:**
- Create: `lib/stackcoin_web/channels/bot_socket.ex`
- Create: `lib/stackcoin_web/channels/bot_channel.ex`
- Modify: `lib/stackcoin_web/endpoint.ex` (add socket declaration)
- Test: `test/stackcoin_web/channels/bot_channel_test.exs`

**Step 1: Write the test**

```elixir
defmodule StackCoinWeb.BotChannelTest do
  use StackCoinWeb.ConnCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{bot: bot, recipient: recipient, bot_token: bot.token}
  end

  test "can connect with valid bot token", %{bot_token: bot_token} do
    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

    assert socket.assigns.bot.token == bot_token
  end

  test "rejects connection with invalid token" do
    assert :error = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => "invalid"})
  end

  test "rejects connection without token" do
    assert :error = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{})
  end

  test "can join user channel matching own user_id", %{bot: bot, bot_token: bot_token} do
    {:ok, socket} = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

    assert {:ok, _reply, _socket} =
             Phoenix.ChannelTest.join(socket, "user:#{bot.user.id}", %{"last_event_id" => 0})
  end

  test "cannot join another user's channel", %{bot_token: bot_token} do
    {:ok, socket} = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

    assert {:error, %{reason: "unauthorized"}} =
             Phoenix.ChannelTest.join(socket, "user:99999", %{"last_event_id" => 0})
  end

  test "receives events in real-time after joining", %{bot: bot, bot_token: bot_token, recipient: recipient} do
    {:ok, socket} = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})
    {:ok, _reply, socket} = Phoenix.ChannelTest.join(socket, "user:#{bot.user.id}", %{"last_event_id" => 0})

    # Perform a transfer that should generate an event
    {:ok, _txn} = Bank.transfer_between_users(bot.user.id, recipient.id, 10, "ws test")

    # Should receive the event via the channel
    assert_push "event", %{type: "transfer.completed", data: data}
    assert data["amount"] == 10
  end

  test "replays missed events on join", %{bot: bot, bot_token: bot_token, recipient: recipient} do
    # Create some events BEFORE connecting
    {:ok, _txn} = Bank.transfer_between_users(bot.user.id, recipient.id, 5, "before connect")

    {:ok, socket} = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})
    {:ok, _reply, _socket} = Phoenix.ChannelTest.join(socket, "user:#{bot.user.id}", %{"last_event_id" => 0})

    # Should receive replayed events
    assert_push "event", %{type: "transfer.completed"}
  end
end
```

**Step 2: Run to verify it fails**

Run: `mix test test/stackcoin_web/channels/bot_channel_test.exs`
Expected: FAIL

**Step 3: Implement BotSocket**

```elixir
defmodule StackCoinWeb.BotSocket do
  use Phoenix.Socket

  channel "user:*", StackCoinWeb.BotChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case StackCoin.Core.Bot.get_bot_by_token(token) do
      {:ok, bot} ->
        # Load the underlying user record for the bot
        {:ok, user} = StackCoin.Core.User.get_user_by_id(bot.user_id)
        {:ok, socket |> assign(:bot, bot) |> assign(:user, user)}
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user.id}"
end
```

**Step 4: Implement BotChannel**

```elixir
defmodule StackCoinWeb.BotChannel do
  use Phoenix.Channel

  alias StackCoin.Core.Event

  @impl true
  def join("user:" <> user_id_str, payload, socket) do
    user_id = String.to_integer(user_id_str)

    if user_id == socket.assigns.user.id do
      # Subscribe to real-time events for this user
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "user:#{user_id}")

      last_event_id = Map.get(payload, "last_event_id", 0)
      send(self(), {:replay_events, last_event_id})
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:replay_events, last_event_id}, socket) do
    events = Event.list_events_since(socket.assigns.user.id, last_event_id)

    for event <- events do
      push(socket, "event", Event.serialize_event(event))
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:event, event_data}, socket) do
    push(socket, "event", event_data)
    {:noreply, socket}
  end
end
```

**Step 5: Add socket to endpoint.ex**

In `lib/stackcoin_web/endpoint.ex`, add before the LiveView socket:

```elixir
socket "/bot", StackCoinWeb.BotSocket,
  websocket: true,
  longpoll: false
```

**Step 6: Run tests**

Run: `mix test test/stackcoin_web/channels/bot_channel_test.exs`
Expected: PASS

**Step 7: Run full suite**

Run: `mix test`
Expected: All pass

**Step 8: Commit**

```
git add lib/stackcoin_web/channels/ lib/stackcoin_web/endpoint.ex test/stackcoin_web/channels/
git commit -m "feat: add WebSocket gateway for real-time bot events"
```

---

## Phase 3: Idempotency Keys

### Task 6: Create idempotency_keys migration and plug

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_create_idempotency_keys.exs`
- Create: `lib/stackcoin/schema/idempotency_key.ex`
- Create: `lib/stackcoin/core/idempotency.ex`
- Test: `test/stackcoin/core/idempotency_test.exs`

**Step 1: Write the migration**

```elixir
defmodule StackCoin.Repo.Migrations.CreateIdempotencyKeys do
  use Ecto.Migration

  def change do
    create table(:idempotency_keys) do
      add :key, :string, null: false
      add :bot_id, references(:bot_user, column: :id, type: :integer), null: false
      add :response_code, :integer, null: false
      add :response_body, :text, null: false
      add :inserted_at, :naive_datetime, null: false, default: fragment("CURRENT_TIMESTAMP")
    end

    create unique_index(:idempotency_keys, [:bot_id, :key])
  end
end
```

**Step 2: Write the schema**

```elixir
defmodule StackCoin.Schema.IdempotencyKey do
  use Ecto.Schema
  import Ecto.Changeset

  schema "idempotency_keys" do
    field :key, :string
    field :bot_id, :integer
    field :response_code, :integer
    field :response_body, :string
    field :inserted_at, :naive_datetime
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:key, :bot_id, :response_code, :response_body])
    |> validate_required([:key, :bot_id, :response_code, :response_body])
    |> unique_constraint([:bot_id, :key])
  end
end
```

**Step 3: Write core module and test**

Test:

```elixir
defmodule StackCoin.Core.IdempotencyTest do
  use StackCoin.DataCase

  alias StackCoin.Core.Idempotency

  test "stores and retrieves a response" do
    assert :miss = Idempotency.check(1, "key-1")

    :ok = Idempotency.store(1, "key-1", 200, ~s({"success": true}))

    assert {:hit, 200, ~s({"success": true})} = Idempotency.check(1, "key-1")
  end

  test "different bots can use the same key" do
    :ok = Idempotency.store(1, "shared-key", 200, ~s({"bot": 1}))
    assert :miss = Idempotency.check(2, "shared-key")
  end

  test "returns miss for unknown key" do
    assert :miss = Idempotency.check(1, "nonexistent")
  end
end
```

Implementation:

```elixir
defmodule StackCoin.Core.Idempotency do
  alias StackCoin.Repo
  alias StackCoin.Schema.IdempotencyKey

  def check(bot_id, key) do
    case Repo.get_by(IdempotencyKey, bot_id: bot_id, key: key) do
      nil -> :miss
      record -> {:hit, record.response_code, record.response_body}
    end
  end

  def store(bot_id, key, response_code, response_body) do
    %IdempotencyKey{}
    |> IdempotencyKey.changeset(%{
      bot_id: bot_id,
      key: key,
      response_code: response_code,
      response_body: response_body
    })
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> :ok  # duplicate key, already stored
    end
  end
end
```

**Step 4: Run tests**

Run: `mix test test/stackcoin/core/idempotency_test.exs`
Expected: PASS

**Step 5: Commit**

```
git add priv/repo/migrations/*_create_idempotency_keys.exs lib/stackcoin/schema/idempotency_key.ex lib/stackcoin/core/idempotency.ex test/stackcoin/core/idempotency_test.exs
git commit -m "feat: add idempotency key storage and lookup"
```

---

### Task 7: Add idempotency plug to transfer and request controllers

**Files:**
- Create: `lib/stackcoin_web/plugs/idempotency.ex`
- Modify: `lib/stackcoin_web/controllers/transfer_controller.ex`
- Modify: `lib/stackcoin_web/controllers/request_controller.ex`
- Test: `test/stackcoin_web/controllers/idempotency_test.exs`

**Step 1: Write the test**

```elixir
defmodule StackCoinWebTest.IdempotencyTest do
  use StackCoinWeb.ConnCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{bot: bot, recipient: recipient, bot_token: bot.token}
  end

  test "same idempotency key returns same response without double-sending", %{
    conn: conn,
    bot_token: bot_token,
    bot: bot,
    recipient: recipient
  } do
    # First request
    conn1 =
      conn
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> put_req_header("idempotency-key", "unique-key-1")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 25})

    response1 = json_response(conn1, 200)
    assert response1["success"] == true
    assert response1["from_new_balance"] == 125

    # Second request with same key - should return cached response
    conn2 =
      build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> put_req_header("idempotency-key", "unique-key-1")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 25})

    response2 = json_response(conn2, 200)

    # Should be same response, not a new transfer
    assert response2 == response1

    # Verify balance only changed once
    {:ok, updated_bot} = User.get_user_by_id(bot.user.id)
    assert updated_bot.balance == 125
  end

  test "different idempotency keys create different transfers", %{
    conn: conn,
    bot_token: bot_token,
    recipient: recipient
  } do
    conn1 =
      conn
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> put_req_header("idempotency-key", "key-a")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 10})

    assert json_response(conn1, 200)["from_new_balance"] == 140

    conn2 =
      build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> put_req_header("idempotency-key", "key-b")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 10})

    assert json_response(conn2, 200)["from_new_balance"] == 130
  end

  test "requests without idempotency key work normally (no caching)", %{
    conn: conn,
    bot_token: bot_token,
    recipient: recipient
  } do
    conn1 =
      conn
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 10})

    assert json_response(conn1, 200)["from_new_balance"] == 140

    conn2 =
      build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 10})

    # Without idempotency key, this creates a second transfer
    assert json_response(conn2, 200)["from_new_balance"] == 130
  end
end
```

**Step 2: Run to verify it fails**

Run: `mix test test/stackcoin_web/controllers/idempotency_test.exs`
Expected: FAIL

**Step 3: Implementation approach**

The idempotency logic is best implemented as a wrapper in the controller actions (not a plug, since we need the response body after the action completes). The pattern:

1. Before processing: check `Idempotency.check(bot_id, key)` - if hit, return cached response
2. After processing: store `Idempotency.store(bot_id, key, status, body)`

Modify `transfer_controller.ex` `send_stk` action:

```elixir
def send_stk(conn, params) do
  idempotency_key = get_req_header(conn, "idempotency-key") |> List.first()

  if idempotency_key do
    case Idempotency.check(conn.assigns.current_bot.id, idempotency_key) do
      {:hit, code, body} ->
        conn
        |> put_status(code)
        |> json(Jason.decode!(body))

      :miss ->
        conn = do_send_stk(conn, params)
        Idempotency.store(
          conn.assigns.current_bot.id,
          idempotency_key,
          conn.status,
          Jason.encode!(conn.resp_body |> Jason.decode!())
        )
        conn
    end
  else
    do_send_stk(conn, params)
  end
end
```

Apply the same pattern to `request_controller.ex` `create` action.

**Step 4: Run tests**

Run: `mix test test/stackcoin_web/controllers/idempotency_test.exs`
Expected: PASS

**Step 5: Run full suite**

Run: `mix test`
Expected: All pass

**Step 6: Commit**

```
git add lib/stackcoin_web/controllers/transfer_controller.ex lib/stackcoin_web/controllers/request_controller.ex test/stackcoin_web/controllers/idempotency_test.exs
git commit -m "feat: add idempotency key support for send and request endpoints"
```

---

## Phase 4: Restructure LuckyPot as an Importable Package + Fix Bugs

### Task 8: Restructure LuckyPot as a proper Python package

LuckyPot needs to be importable so E2E tests can exercise its real code directly (not reimplementations). The Discord bot entry point becomes a thin CLI runner; the business logic lives in a `luckypot/` package.

**Files:**
- Create: `tmp/LuckyPot/luckypot/__init__.py`
- Move: `tmp/LuckyPot/db.py` -> `tmp/LuckyPot/luckypot/db.py`
- Move: `tmp/LuckyPot/stk.py` -> `tmp/LuckyPot/luckypot/stk.py`
- Move: `tmp/LuckyPot/config.py` -> `tmp/LuckyPot/luckypot/config.py`
- Create: `tmp/LuckyPot/luckypot/game.py` (extracted game logic from lucky_pot.py)
- Modify: `tmp/LuckyPot/lucky_pot.py` (thin CLI runner, imports from luckypot package)
- Modify: `tmp/LuckyPot/pyproject.toml` (declare as installable package)

**Step 1: Update pyproject.toml to be an installable package**

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
    "python-dotenv>=1.1.1",
    "schedule>=1.2.0",
    "websockets>=13.0",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["luckypot"]
```

**Step 2: Create `luckypot/__init__.py`**

```python
"""LuckyPot - A lottery bot for StackCoin."""
```

**Step 3: Move modules into the package**

```bash
mkdir -p tmp/LuckyPot/luckypot
mv tmp/LuckyPot/db.py tmp/LuckyPot/luckypot/db.py
mv tmp/LuckyPot/stk.py tmp/LuckyPot/luckypot/stk.py
mv tmp/LuckyPot/config.py tmp/LuckyPot/luckypot/config.py
```

**Step 4: Extract game logic into `luckypot/game.py`**

Move the non-Discord business logic out of `lucky_pot.py` into `luckypot/game.py`. This includes:
- `send_winnings_to_user()`
- `process_pot_win()`
- `end_pot_with_winner()`
- `daily_pot_draw()`
- `select_random_winner()`
- `process_stackcoin_requests()` (until we replace it with gateway)
- Constants: `POT_ENTRY_COST`, `DAILY_DRAW_CHANCE`, `RANDOM_WIN_CHANCE`
- The pot entry logic (extracted as a function, not a Discord command handler)

```python
"""
LuckyPot game logic -- the core business rules, independent of Discord.

This module can be imported and tested directly without a Discord bot running.
"""
import random
from typing import Callable, Awaitable

from loguru import logger

from luckypot import db, stk

POT_ENTRY_COST = 5
DAILY_DRAW_CHANCE = 0.6
RANDOM_WIN_CHANCE = 0.05


async def enter_pot(
    discord_id: str,
    guild_id: str,
    announce_fn: Callable[[str, str], Awaitable[None]] | None = None,
) -> dict:
    """
    Core pot entry logic. Returns a result dict with keys:
      - status: "entered" | "instant_win" | "already_entered" | "not_registered" | "payment_failed"
      - entry_id: int (if entered)
      - request_id: str (if entered)
      - pot_total: int (if instant_win)

    The announce_fn callback is called for guild announcements (optional,
    allows the Discord layer to inject its own announcement mechanism).
    """
    user = await stk.get_user_by_discord_id(discord_id)
    if not user:
        return {"status": "not_registered"}

    if not isinstance(user.id, int):
        raise Exception("User ID is not an integer")

    # Check duplicate BEFORE creating payment request
    with db.get_transaction() as conn:
        db.get_or_create_user(conn, discord_id, guild_id)
        current_pot = db.get_current_pot(conn, guild_id)
        if not current_pot:
            pot_id = db.create_new_pot(conn, guild_id)
        else:
            pot_id = current_pot["pot_id"]

        if not db.can_user_enter_pot(conn, discord_id, guild_id, pot_id):
            return {"status": "already_entered"}

    # Now create payment request (after we know entry is valid)
    request_id = await stk.create_payment_request(user.id, POT_ENTRY_COST, "Lucky Pot Entry")
    if not request_id:
        return {"status": "payment_failed"}

    instant_win = random.random() < RANDOM_WIN_CHANCE

    with db.get_transaction() as conn:
        # Re-check in case of race (UNIQUE constraint is the final safety net)
        if not db.can_user_enter_pot(conn, discord_id, guild_id, pot_id):
            await stk.deny_request(request_id)
            return {"status": "already_entered"}

        entry_id = db.create_pot_entry(conn, pot_id, discord_id, guild_id, request_id, instant_win)

        if instant_win:
            current_status = db.get_pot_status(conn, guild_id)
            pot_total = (current_status.get("total_amount", 0) if current_status else 0) + POT_ENTRY_COST
            return {
                "status": "instant_win",
                "entry_id": entry_id,
                "request_id": request_id,
                "pot_total": pot_total,
                "username": user.username,
            }

    return {
        "status": "entered",
        "entry_id": entry_id,
        "request_id": request_id,
        "username": user.username,
    }


def select_random_winner(participants: list[db.Participant]) -> str:
    """Select a random winner from participants."""
    participant_ids = [p["discord_id"] for p in participants]
    return random.choice(participant_ids)


async def send_winnings_to_user(winner_discord_id: str, amount: int) -> bool:
    """Send STK winnings to the winner, with balance check."""
    bot_balance = await stk.get_bot_balance()
    if bot_balance is None or bot_balance < amount:
        logger.error(f"Insufficient bot balance ({bot_balance}) to pay {amount} STK")
        return False
    return await stk.send_stk(winner_discord_id, amount, "Lucky Pot Winnings")


async def process_pot_win(
    conn,
    guild_id: str,
    winner_id: str,
    winning_amount: int,
    win_type: str = "DAILY DRAW",
    announce_fn: Callable[[str, str], Awaitable[None]] | None = None,
) -> bool:
    """Process a pot win: send winnings and update DB."""
    if await send_winnings_to_user(winner_id, winning_amount):
        db.win_pot(conn, guild_id, winner_id, winning_amount)
        logger.info(f"{win_type} winner in guild {guild_id}: {winner_id} won {winning_amount} STK")

        if announce_fn:
            msg = (
                f"**{win_type} WINNER!**\n\n"
                f"<@{winner_id}> has won the pot of **{winning_amount} STK**!\n"
                f"A new pot has started - use `/enter-pot` to join!"
            )
            await announce_fn(guild_id, msg)
        return True
    else:
        logger.error(f"Failed to send winnings to {winner_id} in guild {guild_id}")
        return False


async def end_pot_with_winner(
    guild_id: str,
    win_type: str = "DAILY DRAW",
    announce_fn: Callable[[str, str], Awaitable[None]] | None = None,
) -> dict | None:
    """End a pot by selecting and paying a winner. Returns winner info or None."""
    with db.get_transaction() as conn:
        pot_status = db.get_pot_status(conn, guild_id)
        if pot_status is None or pot_status["participant_count"] == 0:
            return None

        participants = db.get_active_pot_participants(conn, guild_id)
        if not participants:
            return None

        winner_id = select_random_winner(participants)
        winning_amount = pot_status["total_amount"]

        if await process_pot_win(conn, guild_id, winner_id, winning_amount, win_type, announce_fn):
            return {
                "winner_id": winner_id,
                "winning_amount": winning_amount,
                "participant_count": pot_status["participant_count"],
            }
    return None


async def daily_pot_draw(
    announce_fn: Callable[[str, str], Awaitable[None]] | None = None,
):
    """Daily pot draw at UTC 0 with configurable win chance."""
    with db.get_connection() as conn:
        all_guilds = db.get_all_active_guilds(conn)

    for guild_id in all_guilds:
        with db.get_connection() as conn:
            pot_status = db.get_pot_status(conn, guild_id)
            if pot_status is None or pot_status["participant_count"] == 0:
                continue

            # Skip if there are pending instant-win entries
            if db.has_pending_instant_wins(conn, guild_id):
                logger.info(f"Skipping draw for guild {guild_id}: pending instant win")
                continue

        if random.random() < DAILY_DRAW_CHANCE:
            winner_info = await end_pot_with_winner(guild_id, "DAILY DRAW", announce_fn)
            if not winner_info and announce_fn:
                await announce_fn(
                    guild_id,
                    f"Daily draw occurred, but no eligible winners. "
                    f"Current pot: **{pot_status['total_amount']} STK**",
                )
        else:
            if announce_fn:
                await announce_fn(
                    guild_id,
                    f"Daily draw occurred, but the pot continues! No winner this time.\n"
                    f"Current pot: **{pot_status['total_amount']} STK**",
                )


async def on_request_accepted(event: dict):
    """Handle a payment request being accepted -- confirm the pot entry."""
    request_id = str(event["data"]["request_id"])

    with db.get_connection() as conn:
        entry = db.get_entry_by_request_id(conn, request_id)
        if not entry:
            return

    if entry["status"] == "instant_win":
        with db.get_transaction() as conn:
            db.confirm_entry(conn, entry["entry_id"])
            pot_status = db.get_pot_status(conn, entry["pot_guild_id"])
            if pot_status is not None:
                await process_pot_win(
                    conn, entry["pot_guild_id"], entry["discord_id"],
                    pot_status["total_amount"], "INSTANT WIN"
                )
    elif entry["status"] == "unconfirmed":
        with db.get_transaction() as conn:
            db.confirm_entry(conn, entry["entry_id"])

    logger.info(f"Confirmed entry {entry['entry_id']} via event")


async def on_request_denied(event: dict):
    """Handle a payment request being denied -- mark entry as denied."""
    request_id = str(event["data"]["request_id"])

    with db.get_connection() as conn:
        entry = db.get_entry_by_request_id(conn, request_id)
        if entry and entry["status"] in ("unconfirmed", "instant_win"):
            with db.get_transaction() as conn:
                db.deny_entry(conn, entry["entry_id"])
            logger.info(f"Denied entry {entry['entry_id']} via event")
```

**Step 5: Update `lucky_pot.py` to be a thin Discord bot runner**

`lucky_pot.py` shrinks to just Discord command wiring that delegates to `luckypot.game`:

```python
"""LuckyPot Discord Bot -- thin CLI runner that wires Discord commands to game logic."""
import asyncio

import hikari
import lightbulb
import schedule
from loguru import logger

from luckypot import config, db, game
from luckypot.gateway import StackCoinGateway


# ... Discord bot setup, slash commands that call game.enter_pot(), etc.
# The commands become thin wrappers:

@lightbulb_client.register(guilds=guilds)
class EnterPot(lightbulb.SlashCommand, name="enter-pot", description=f"Enter the daily lucky pot (costs {game.POT_ENTRY_COST} STK)"):
    @lightbulb.invoke
    async def invoke(self, ctx: lightbulb.Context) -> None:
        result = await game.enter_pot(str(ctx.user.id), str(ctx.guild_id), announce_fn=announce_to_guild)
        match result["status"]:
            case "not_registered":
                await ctx.respond("Not registered with StackCoin! Run /dole first.")
            case "already_entered":
                await ctx.respond("You've already entered this pot!")
            case "payment_failed":
                await ctx.respond("Failed to create payment request.")
            case "instant_win":
                await ctx.respond(f"INSTANT WIN! You've won {result['pot_total']} STK!")
            case "entered":
                await ctx.respond(f"Accept the {game.POT_ENTRY_COST} STK payment request via DMs!")
```

**Step 6: Verify package is installable**

Run: `pip install -e tmp/LuckyPot` (from the repo root)
Expected: Installs successfully, `import luckypot` works

**Step 7: Commit**

```
git add tmp/LuckyPot/
git commit -m "refactor: restructure LuckyPot as importable Python package"
```

---

### Task 9: Fix instant-win race condition and pot status visibility

**Files:**
- Modify: `tmp/LuckyPot/luckypot/db.py`

The fix: `get_pot_status` and `get_active_pot_participants` must include `instant_win` entries in their counts. Add `has_pending_instant_wins` helper for daily draw safety.

In `db.py`, update `get_pot_status` queries:

```python
# Change status filter from just 'confirmed' to include 'instant_win'
WHERE pot_id = ? AND status IN ('confirmed', 'instant_win')
```

Add helper:

```python
def has_pending_instant_wins(conn: sqlite3.Connection, guild_id: str) -> bool:
    """Check if there are unresolved instant_win entries for the active pot."""
    cursor = conn.execute("""
        SELECT COUNT(*) FROM pot_entries pe
        JOIN pots p ON pe.pot_id = p.pot_id
        WHERE p.guild_id = ? AND p.is_active = TRUE AND pe.status = 'instant_win'
    """, (guild_id,))
    return cursor.fetchone()[0] > 0
```

Add `get_entry_by_request_id`:

```python
def get_entry_by_request_id(conn: sqlite3.Connection, request_id: str) -> PotEntry | None:
    cursor = conn.execute("""
        SELECT pe.*, p.guild_id as pot_guild_id
        FROM pot_entries pe
        JOIN pots p ON pe.pot_id = p.pot_id
        WHERE pe.stackcoin_request_id = ?
    """, (request_id,))
    row = cursor.fetchone()
    return PotEntry(**dict(row)) if row else None
```

**Commit:**

```
git add tmp/LuckyPot/luckypot/db.py
git commit -m "fix: include instant_win entries in pot status, add pending instant win check"
```

---

### Task 10: Remove dead schema and add bot balance check

**Files:**
- Modify: `tmp/LuckyPot/luckypot/db.py` (remove `stackcoin_requests` table creation)
- Modify: `tmp/LuckyPot/luckypot/stk.py` (add `get_bot_balance` function)

Remove the `stackcoin_requests` CREATE TABLE from `init_database()`.

Add to `stk.py`:

```python
from stackcoin_python.api.default import stackcoin_user_me
from stackcoin_python.models import UserResponse

async def get_bot_balance() -> int | None:
    """Get the bot's current STK balance"""
    try:
        async with get_client() as client:
            response = await stackcoin_user_me.asyncio(client=client)
            if isinstance(response, UserResponse):
                return response.balance
            return None
    except Exception as e:
        logger.error(f"Error getting bot balance: {e}")
        return None
```

Note: The balance check is already integrated into `game.send_winnings_to_user()` from Task 8.

**Commit:**

```
git add tmp/LuckyPot/luckypot/db.py tmp/LuckyPot/luckypot/stk.py
git commit -m "fix: remove dead schema, add bot balance check"
```

---

## Phase 5: End-to-End Testing

### Task 11: Create E2E test infrastructure

The E2E tests exercise the **real LuckyPot code** against a **real StackCoin server**. No mocks, no reimplementations. The `luckypot` package is installed as an editable local dependency so tests can `from luckypot import game, db, stk` and call the same functions the production bot uses.

The E2E tests will:
1. Start a real StackCoin Phoenix server (test mode, fixed port)
2. Import and run real LuckyPot game logic against it via HTTP
3. Simulate the full flow: user entry -> payment request -> accept -> confirm -> payout

**Files:**
- Create: `test/e2e/conftest.py` (pytest fixtures for StackCoin server + bot setup)
- Create: `test/e2e/test_stackcoin_api.py` (StackCoin API-level tests)
- Create: `test/e2e/test_luckypot.py` (LuckyPot game logic against real server)
- Create: `test/e2e/pyproject.toml` (E2E test project with local deps)

**Step 1: Create E2E test project**

`test/e2e/pyproject.toml`:
```toml
[project]
name = "stackcoin-e2e-tests"
version = "0.1.0"
description = "End-to-end tests for StackCoin and LuckyPot"
requires-python = ">=3.13"
dependencies = [
    "pytest>=8.0",
    "pytest-asyncio>=0.24",
    "httpx>=0.27",
    "websockets>=13.0",
]

[tool.pytest.ini_options]
asyncio_mode = "auto"

# Install the real packages as editable local deps:
#   uv pip install -e "../../tmp/stackcoin-python/stackcoin"
#   uv pip install -e "../../tmp/LuckyPot"
```

`test/e2e/conftest.py`:

```python
"""
E2E test fixtures that start a real StackCoin server and configure test bots.

Both stackcoin-python and luckypot are installed as editable local deps:
  uv pip install -e "../../tmp/stackcoin-python/stackcoin"
  uv pip install -e "../../tmp/LuckyPot"

Requires:
- Elixir/Mix available on PATH
- StackCoin project at the repo root
"""
import os
import signal
import subprocess
import tempfile
import time

import httpx
import pytest


STACKCOIN_ROOT = os.path.join(os.path.dirname(__file__), "../..")


@pytest.fixture(scope="session")
def stackcoin_server():
    """Start a real StackCoin Phoenix server in test mode."""
    port = 4042
    env = {
        **os.environ,
        "MIX_ENV": "test",
        "DATABASE_PATH": "./data/e2e_test.db",
        "PORT": str(port),
        "SECRET_KEY_BASE": "test_secret_key_base_that_is_at_least_64_bytes_long_for_phoenix_to_accept_it",
        "DISCORD_TOKEN": "fake_token_for_testing",
        "ADMIN_USER_ID": "1",
    }

    # Reset test database
    subprocess.run(["mix", "ecto.reset"], env=env, cwd=STACKCOIN_ROOT, capture_output=True)

    # Start server
    proc = subprocess.Popen(
        ["mix", "phx.server"],
        env=env, cwd=STACKCOIN_ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        preexec_fn=os.setsid,
    )

    base_url = f"http://localhost:{port}"

    # Wait for server to be ready
    for _ in range(30):
        try:
            resp = httpx.get(f"{base_url}/api/openapi", timeout=2)
            if resp.status_code == 200:
                break
        except (httpx.ConnectError, httpx.ReadTimeout):
            time.sleep(1)
    else:
        proc.terminate()
        raise RuntimeError("StackCoin server failed to start")

    yield {"base_url": base_url, "port": port}

    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    proc.wait(timeout=10)


@pytest.fixture(scope="session")
def seed_data(stackcoin_server):
    """Seed the test database with users, a bot, and funded balances."""
    result = subprocess.run(
        ["mix", "run", "-e", """
        {:ok, _reserve} = StackCoin.Core.User.create_user_account("1", "Reserve", balance: 10000)
        {:ok, owner} = StackCoin.Core.User.create_user_account("100", "E2EOwner", balance: 0)
        {:ok, bot} = StackCoin.Core.Bot.create_bot_user("100", "E2ETestBot")
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
        """],
        env={**os.environ, "MIX_ENV": "test", "DATABASE_PATH": "./data/e2e_test.db"},
        cwd=STACKCOIN_ROOT,
        capture_output=True, text=True,
    )

    values = {}
    for line in result.stdout.strip().split("\n"):
        if ":" in line:
            key, val = line.split(":", 1)
            if key in ("BOT_TOKEN", "BOT_USER_ID", "USER1_ID", "USER1_DISCORD_ID", "USER2_ID", "USER2_DISCORD_ID"):
                values[key] = val

    return values


@pytest.fixture
def test_context(stackcoin_server, seed_data):
    """Full test context with all IDs, URLs, and Discord snowflakes."""
    return {
        "base_url": stackcoin_server["base_url"],
        "bot_token": seed_data["BOT_TOKEN"],
        "bot_user_id": int(seed_data["BOT_USER_ID"]),
        "user1_id": int(seed_data["USER1_ID"]),
        "user1_discord_id": seed_data["USER1_DISCORD_ID"],
        "user2_id": int(seed_data["USER2_ID"]),
        "user2_discord_id": seed_data["USER2_DISCORD_ID"],
    }


@pytest.fixture
def api_client(stackcoin_server, seed_data):
    """Authenticated API client for the E2E test bot."""
    from stackcoin_python import AuthenticatedClient
    return AuthenticatedClient(base_url=stackcoin_server["base_url"], token=seed_data["BOT_TOKEN"])


@pytest.fixture
def luckypot_db(tmp_path):
    """
    Provide a fresh LuckyPot SQLite database for each test.
    Patches luckypot.db.DB_PATH to use a temp file.
    """
    import luckypot.db as lp_db

    db_path = str(tmp_path / "test_lucky_pot.db")
    original_path = lp_db.DB_PATH
    lp_db.DB_PATH = db_path
    lp_db.init_database()

    yield db_path

    lp_db.DB_PATH = original_path


@pytest.fixture
def configure_luckypot_stk(stackcoin_server, seed_data):
    """
    Configure luckypot.stk to point at the test StackCoin server.
    Patches luckypot.config with the test credentials.
    """
    import luckypot.config as lp_config

    original_url = lp_config.STACKCOIN_BASE_URL
    original_token = lp_config.STACKCOIN_BOT_TOKEN

    lp_config.STACKCOIN_BASE_URL = stackcoin_server["base_url"]
    lp_config.STACKCOIN_BOT_TOKEN = seed_data["BOT_TOKEN"]

    yield

    lp_config.STACKCOIN_BASE_URL = original_url
    lp_config.STACKCOIN_BOT_TOKEN = original_token
```

**Step 2: Write StackCoin API E2E tests**

`test/e2e/test_stackcoin_api.py` -- tests the StackCoin server directly via the Python client:

```python
"""
E2E tests for the StackCoin API layer.
Tests the real server via stackcoin-python (the real client library).
"""
import pytest
import httpx as raw_httpx

from stackcoin_python import AuthenticatedClient
from stackcoin_python.models import *
from stackcoin_python.api.default import *


@pytest.mark.asyncio
class TestPaymentRequestLifecycle:

    async def test_create_request_returns_pending(self, api_client, test_context):
        async with api_client as client:
            response = await stackcoin_create_request.asyncio(
                client=client,
                user_id=test_context["user1_id"],
                body=CreateRequestParams(amount=10, label="E2E test"),
            )
            assert isinstance(response, CreateRequestResponse)
            assert response.success is True
            assert response.status == "pending"

    async def test_deny_request(self, api_client, test_context):
        async with api_client as client:
            create_resp = await stackcoin_create_request.asyncio(
                client=client,
                user_id=test_context["user1_id"],
                body=CreateRequestParams(amount=5, label="E2E deny test"),
            )
            assert isinstance(create_resp, CreateRequestResponse)

            deny_resp = await stackcoin_deny_request.asyncio(
                client=client, request_id=create_resp.request_id,
            )
            assert isinstance(deny_resp, RequestActionResponse)
            assert deny_resp.status == "denied"


@pytest.mark.asyncio
class TestDirectTransfer:

    async def test_send_stk_success(self, api_client, test_context):
        async with api_client as client:
            response = await stackcoin_send_stk.asyncio(
                client=client,
                user_id=test_context["user1_id"],
                body=SendStkParams(amount=5, label="E2E transfer"),
            )
            assert isinstance(response, SendStkResponse)
            assert response.success is True

    async def test_send_stk_insufficient_balance(self, api_client, test_context):
        async with api_client as client:
            response = await stackcoin_send_stk.asyncio(
                client=client,
                user_id=test_context["user1_id"],
                body=SendStkParams(amount=999999),
            )
            assert isinstance(response, ErrorResponse)
            assert response.error == "insufficient_balance"


@pytest.mark.asyncio
class TestIdempotency:

    async def test_duplicate_send_with_same_key(self, test_context):
        base = test_context["base_url"]
        token = test_context["bot_token"]
        user_id = test_context["user1_id"]

        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Idempotency-Key": "e2e-idem-key-1",
        }

        async with raw_httpx.AsyncClient(base_url=base) as client:
            r1 = await client.post(
                f"/api/user/{user_id}/send",
                json={"amount": 3, "label": "idempotent test"},
                headers=headers,
            )
            r2 = await client.post(
                f"/api/user/{user_id}/send",
                json={"amount": 3, "label": "idempotent test"},
                headers=headers,
            )
            assert r1.json()["transaction_id"] == r2.json()["transaction_id"]


@pytest.mark.asyncio
class TestEventDelivery:

    async def test_events_appear_after_transfer(self, test_context):
        base = test_context["base_url"]
        token = test_context["bot_token"]
        user_id = test_context["user1_id"]
        headers = {"Authorization": f"Bearer {token}"}

        async with raw_httpx.AsyncClient(base_url=base) as client:
            events_before = await client.get("/api/events", headers=headers)
            before_count = len(events_before.json().get("events", []))

            await client.post(
                f"/api/user/{user_id}/send",
                json={"amount": 1, "label": "event test"},
                headers={**headers, "Content-Type": "application/json"},
            )

            events_after = await client.get("/api/events", headers=headers)
            after_events = events_after.json()["events"]
            assert len(after_events) > before_count

            transfer_events = [e for e in after_events if e["type"] == "transfer.completed"]
            assert len(transfer_events) > 0


@pytest.mark.asyncio
class TestConcurrency:

    async def test_rapid_sequential_transfers(self, test_context):
        base = test_context["base_url"]
        token = test_context["bot_token"]
        user_id = test_context["user1_id"]

        async with raw_httpx.AsyncClient(base_url=base) as client:
            headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

            me = await client.get("/api/user/me", headers=headers)
            starting_balance = me.json()["balance"]

            successes = 0
            for i in range(10):
                resp = await client.post(
                    f"/api/user/{user_id}/send",
                    json={"amount": 1, "label": f"rapid-{i}"},
                    headers=headers,
                )
                if resp.status_code == 200 and resp.json().get("success"):
                    successes += 1

            me_after = await client.get("/api/user/me", headers=headers)
            assert me_after.json()["balance"] == starting_balance - successes
```

**Step 3: Write LuckyPot E2E tests -- importing the real code**

`test/e2e/test_luckypot.py`:

```python
"""
E2E tests for LuckyPot game logic against a real StackCoin server.

These tests import the REAL luckypot package (not reimplementations) and
exercise its game logic, db module, and stk module against the live
StackCoin test server.
"""
import pytest

from luckypot import db, game, stk


@pytest.mark.asyncio
class TestLuckyPotEntryFlow:
    """Test the real LuckyPot enter_pot() function against a live server."""

    async def test_enter_pot_unregistered_user(self, luckypot_db, configure_luckypot_stk):
        """Unregistered Discord user should get not_registered."""
        result = await game.enter_pot(
            discord_id="999999999",  # Not in StackCoin
            guild_id="test_guild_1",
        )
        assert result["status"] == "not_registered"

    async def test_enter_pot_success(self, luckypot_db, configure_luckypot_stk, test_context):
        """Registered user enters the pot -- creates a payment request on StackCoin."""
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        # Should be "entered" or "instant_win" (5% chance)
        assert result["status"] in ("entered", "instant_win")
        assert "request_id" in result
        assert "entry_id" in result

        # Verify the entry exists in LuckyPot's local DB
        with db.get_connection() as conn:
            entry = db.get_entry_by_id(conn, result["entry_id"])
            assert entry is not None
            assert entry["stackcoin_request_id"] == result["request_id"]

    async def test_enter_pot_duplicate_blocked(self, luckypot_db, configure_luckypot_stk, test_context):
        """Second entry attempt for same user in same pot should be rejected."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        assert result1["status"] in ("entered", "instant_win")

        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        assert result2["status"] == "already_entered"

    async def test_multiple_users_enter_same_pot(self, luckypot_db, configure_luckypot_stk, test_context):
        """Multiple users can enter the same pot."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        result2 = await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id="test_guild_1",
        )
        assert result1["status"] in ("entered", "instant_win")
        assert result2["status"] in ("entered", "instant_win")

        # Both should reference the same pot
        with db.get_connection() as conn:
            e1 = db.get_entry_by_id(conn, result1["entry_id"])
            e2 = db.get_entry_by_id(conn, result2["entry_id"])
            assert e1["pot_id"] == e2["pot_id"]

    async def test_separate_guilds_separate_pots(self, luckypot_db, configure_luckypot_stk, test_context):
        """Same user can enter pots in different guilds."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_A",
        )
        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_B",
        )
        assert result1["status"] in ("entered", "instant_win")
        assert result2["status"] in ("entered", "instant_win")


@pytest.mark.asyncio
class TestLuckyPotPayout:
    """Test pot payout using real stk.send_stk() against the live server."""

    async def test_send_winnings_success(self, configure_luckypot_stk, test_context):
        """Bot can send winnings to a user."""
        success = await game.send_winnings_to_user(
            test_context["user1_discord_id"], 10,
        )
        assert success is True

    async def test_send_winnings_insufficient_balance(self, configure_luckypot_stk, test_context):
        """Payout fails gracefully when bot balance is too low."""
        success = await game.send_winnings_to_user(
            test_context["user1_discord_id"], 999999,
        )
        assert success is False


@pytest.mark.asyncio
class TestLuckyPotDb:
    """Test LuckyPot's local DB operations (using real db module)."""

    def test_pot_lifecycle(self, luckypot_db):
        """Create pot, add entries, check status, win pot."""
        with db.get_transaction() as conn:
            db.get_or_create_user(conn, "user1", "guild1")
            db.get_or_create_user(conn, "user2", "guild1")

            pot_id = db.create_new_pot(conn, "guild1")
            assert pot_id is not None

            # Add entries
            e1 = db.create_pot_entry(conn, pot_id, "user1", "guild1", "req_1", False)
            e2 = db.create_pot_entry(conn, pot_id, "user2", "guild1", "req_2", False)

            # Confirm entries
            db.confirm_entry(conn, e1)
            db.confirm_entry(conn, e2)

            # Check status
            status = db.get_pot_status(conn, "guild1")
            assert status is not None
            assert status["participant_count"] == 2
            assert status["total_amount"] == 10  # 5 * 2

            # Win pot
            db.win_pot(conn, "guild1", "user1", 10)

            # Pot should no longer be active
            assert db.get_current_pot(conn, "guild1") is None

    def test_instant_win_included_in_status(self, luckypot_db):
        """Instant-win entries should be counted in pot status."""
        with db.get_transaction() as conn:
            db.get_or_create_user(conn, "user1", "guild1")

            pot_id = db.create_new_pot(conn, "guild1")
            e1 = db.create_pot_entry(conn, pot_id, "user1", "guild1", "req_1", True)  # instant_win

            status = db.get_pot_status(conn, "guild1")
            assert status is not None
            # instant_win entry should be counted
            assert status["participant_count"] == 1
            assert status["total_amount"] == 5

    def test_duplicate_entry_blocked(self, luckypot_db):
        """Same user cannot enter the same pot twice."""
        with db.get_transaction() as conn:
            db.get_or_create_user(conn, "user1", "guild1")
            pot_id = db.create_new_pot(conn, "guild1")
            db.create_pot_entry(conn, pot_id, "user1", "guild1", "req_1", False)

            assert db.can_user_enter_pot(conn, "user1", "guild1", pot_id) is False


@pytest.mark.asyncio
class TestLuckyPotEventHandlers:
    """Test the event handlers that will be wired to the WebSocket gateway."""

    async def test_on_request_accepted_confirms_entry(self, luckypot_db, configure_luckypot_stk):
        """Simulating a request.accepted event should confirm an unconfirmed entry."""
        with db.get_transaction() as conn:
            db.get_or_create_user(conn, "user1", "guild1")
            pot_id = db.create_new_pot(conn, "guild1")
            entry_id = db.create_pot_entry(conn, pot_id, "user1", "guild1", "12345", False)

        # Simulate the event that would come from the WebSocket gateway
        event = {"data": {"request_id": 12345}}
        await game.on_request_accepted(event)

        with db.get_connection() as conn:
            entry = db.get_entry_by_id(conn, entry_id)
            assert entry["status"] == "confirmed"

    async def test_on_request_denied_denies_entry(self, luckypot_db, configure_luckypot_stk):
        """Simulating a request.denied event should deny an unconfirmed entry."""
        with db.get_transaction() as conn:
            db.get_or_create_user(conn, "user1", "guild1")
            pot_id = db.create_new_pot(conn, "guild1")
            entry_id = db.create_pot_entry(conn, pot_id, "user1", "guild1", "99999", False)

        event = {"data": {"request_id": 99999}}
        await game.on_request_denied(event)

        with db.get_connection() as conn:
            entry = db.get_entry_by_id(conn, entry_id)
            assert entry["status"] == "denied"
```

**Step 4: Commit**

```
git add test/e2e/
git commit -m "feat: add E2E tests importing real LuckyPot and stackcoin-python packages"
```

---

### Task 12: Add WebSocket E2E test

**Files:**
- Modify: `test/e2e/requirements.txt` (add websockets)
- Create: `test/e2e/test_websocket_gateway.py`

This test validates the WebSocket gateway works end-to-end using a raw WebSocket client speaking the Phoenix Channel protocol.

```python
"""
E2E tests for the WebSocket gateway.

Uses the Phoenix Channel protocol over WebSocket to verify
real-time event delivery.
"""
import asyncio
import json

import httpx
import pytest
import websockets


async def phoenix_connect(base_url: str, token: str):
    """Connect to Phoenix Channel and join the bot channel."""
    ws_url = base_url.replace("http://", "ws://") + "/bot/websocket?token=" + token + "&vsn=2.0.0"

    ws = await websockets.connect(ws_url)

    # Join the user events channel
    join_msg = json.dumps(["1", "1", "user:self", "phx_join", {"last_event_id": 0}])
    await ws.send(join_msg)

    # Wait for join reply
    reply = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
    assert reply[3] == "phx_reply"
    assert reply[4]["status"] == "ok"

    return ws


@pytest.mark.asyncio
class TestWebSocketGateway:

    async def test_receives_event_on_transfer(self, test_context):
        """Perform a transfer and verify the event arrives via WebSocket."""
        base = test_context["base_url"]
        token = test_context["bot_token"]
        user_id = test_context["user1_id"]

        ws = await phoenix_connect(base, token)

        try:
            # Perform a transfer via HTTP
            async with httpx.AsyncClient(base_url=base) as client:
                resp = await client.post(
                    f"/api/user/{user_id}/send",
                    json={"amount": 1, "label": "ws e2e test"},
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Content-Type": "application/json",
                    },
                )
                assert resp.status_code == 200

            # Wait for event via WebSocket
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))

            # Phoenix Channel message format: [join_ref, ref, topic, event, payload]
            assert msg[3] == "event"
            assert msg[4]["type"] == "transfer.completed"
            assert msg[4]["data"]["amount"] == 1
        finally:
            await ws.close()
```

Note: The Phoenix Channel wire protocol uses JSON arrays `[join_ref, ref, topic, event, payload]`. The exact format may need adjustment based on the Phoenix version. The test above is a starting point -- the implementer should verify against the actual wire format.

**Step 4: Commit**

```
git add test/e2e/
git commit -m "feat: add WebSocket gateway E2E tests"
```

---

## Phase 6: Add Gateway Client and Idempotency to LuckyPot

### Task 13: Create the StackCoin WebSocket gateway client

**Files:**
- Create: `tmp/LuckyPot/luckypot/gateway.py`
- Modify: `tmp/LuckyPot/lucky_pot.py` (wire gateway + event handlers from game.py)

The gateway client lives in the `luckypot` package so it's importable and testable. The event handlers (`game.on_request_accepted`, `game.on_request_denied`) were already extracted in Task 8.

`tmp/LuckyPot/luckypot/gateway.py`:

```python
"""
StackCoin WebSocket Gateway client.

Connects to the StackCoin Phoenix Channel WebSocket and receives
real-time events. Handles reconnection and event replay.
"""
import asyncio
import json
from typing import Callable, Awaitable

from loguru import logger


EventHandler = Callable[[dict], Awaitable[None]]


class StackCoinGateway:
    def __init__(self, base_url: str, token: str):
        self._base_url = base_url.replace("http://", "ws://").replace("https://", "wss://")
        self._token = token
        self._handlers: dict[str, list[EventHandler]] = {}
        self._last_event_id = 0
        self._ws = None
        self._running = False
        self._ref_counter = 0

    def on(self, event_type: str):
        """Decorator to register an event handler."""
        def decorator(func: EventHandler):
            if event_type not in self._handlers:
                self._handlers[event_type] = []
            self._handlers[event_type].append(func)
            return func
        return decorator

    async def connect(self):
        """Connect and start listening for events. Reconnects on failure."""
        import websockets

        self._running = True

        while self._running:
            try:
                url = f"{self._base_url}/bot/websocket?token={self._token}&vsn=2.0.0"
                async with websockets.connect(url) as ws:
                    self._ws = ws
                    logger.info("Connected to StackCoin gateway")

                    await self._join_channel(ws)

                    heartbeat_task = asyncio.create_task(self._heartbeat(ws))
                    try:
                        async for raw_msg in ws:
                            msg = json.loads(raw_msg)
                            await self._handle_message(msg)
                    finally:
                        heartbeat_task.cancel()

            except Exception as e:
                logger.error(f"Gateway connection error: {e}")
                if self._running:
                    logger.info("Reconnecting in 5 seconds...")
                    await asyncio.sleep(5)

    async def _join_channel(self, ws):
        self._ref_counter += 1
        join_msg = json.dumps([
            None, str(self._ref_counter),
            "user:self", "phx_join",
            {"last_event_id": self._last_event_id},
        ])
        await ws.send(join_msg)

        reply = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
        if reply[3] == "phx_reply" and reply[4].get("status") == "ok":
            logger.info(f"Joined user channel (replaying from event {self._last_event_id})")
        else:
            raise Exception(f"Failed to join channel: {reply}")

    async def _heartbeat(self, ws):
        while True:
            await asyncio.sleep(30)
            self._ref_counter += 1
            hb = json.dumps([None, str(self._ref_counter), "phoenix", "heartbeat", {}])
            await ws.send(hb)

    async def _handle_message(self, msg):
        if len(msg) < 5:
            return

        event_name = msg[3]
        payload = msg[4]

        if event_name == "event":
            event_type = payload.get("type", "")
            event_id = payload.get("id", 0)

            if event_id > self._last_event_id:
                self._last_event_id = event_id

            for handler in self._handlers.get(event_type, []):
                try:
                    await handler(payload)
                except Exception as e:
                    logger.error(f"Error in handler for {event_type}: {e}")

    def stop(self):
        self._running = False
```

In `lucky_pot.py`, wire the gateway to the game logic event handlers:

```python
from luckypot.gateway import StackCoinGateway
from luckypot import config, db, game

gateway = StackCoinGateway(config.STACKCOIN_BASE_URL, config.STACKCOIN_BOT_TOKEN)

# Wire game event handlers to gateway
gateway.on("request.accepted")(game.on_request_accepted)
gateway.on("request.denied")(game.on_request_denied)

async def background_tasks():
    """Run gateway connection and scheduled tasks."""
    asyncio.create_task(gateway.connect())
    while True:
        try:
            schedule.run_pending()
        except Exception as e:
            logger.error(f"Error in scheduled tasks: {e}")
        await asyncio.sleep(1)
```

**Commit:**

```
git add tmp/LuckyPot/luckypot/gateway.py tmp/LuckyPot/lucky_pot.py
git commit -m "feat: add StackCoin WebSocket gateway client, replace polling"
```

---

### Task 14: Add idempotency keys to LuckyPot's STK calls

**Files:**
- Modify: `tmp/LuckyPot/luckypot/stk.py`
- Modify: `tmp/LuckyPot/luckypot/game.py`

Add idempotency key support to `stk.py`:

```python
async def create_payment_request(
    user_id: int, amount: int, label: str = "Lucky Pot Entry",
    idempotency_key: str | None = None,
) -> str | None:
    try:
        async with get_client() as client:
            if idempotency_key:
                client = client.with_headers({"Idempotency-Key": idempotency_key})
            response = await stackcoin_create_request.asyncio(
                client=client, user_id=user_id,
                body=CreateRequestParams(amount=amount, label=label),
            )
            # ...

async def send_stk(
    discord_id: str, amount: int, label: str,
    idempotency_key: str | None = None,
) -> bool:
    # ... same pattern, add Idempotency-Key header if provided
```

In `game.py`, use structured idempotency keys:

```python
# In enter_pot():
idempotency_key = f"pot_entry:{guild_id}:{discord_id}:{pot_id}"
request_id = await stk.create_payment_request(
    user.id, POT_ENTRY_COST, "Lucky Pot Entry",
    idempotency_key=idempotency_key,
)

# In send_winnings_to_user():
# (caller passes idempotency_key down from process_pot_win)
idempotency_key = f"pot_win:{guild_id}:{pot_id}:{winner_discord_id}"
```

**Commit:**

```
git add tmp/LuckyPot/luckypot/stk.py tmp/LuckyPot/luckypot/game.py
git commit -m "feat: add idempotency keys to LuckyPot STK API calls"
```

---

## Summary of All Tasks

| # | Phase | Task | Scope |
|---|-------|------|-------|
| 1 | Events | Events migration + schema | StackCoin |
| 2 | Events | Event core module | StackCoin |
| 3 | Events | Emit events from Bank/Request | StackCoin |
| 4 | Events | REST endpoint for events | StackCoin |
| 5 | WebSocket | BotSocket + BotChannel | StackCoin |
| 6 | Idempotency | Idempotency keys storage | StackCoin |
| 7 | Idempotency | Idempotency plug for controllers | StackCoin |
| 8 | Bug fixes | Fix orphaned payment request | LuckyPot |
| 9 | Bug fixes | Fix instant-win race condition | LuckyPot |
| 10 | Bug fixes | Remove dead schema, add balance check | LuckyPot |
| 11 | E2E Tests | Test infrastructure + initial tests | Cross-cutting |
| 12 | E2E Tests | WebSocket gateway E2E tests | Cross-cutting |
| 13 | Integration | Replace polling with WebSocket gateway | LuckyPot |
| 14 | Integration | Add idempotency keys to LuckyPot | LuckyPot |

**Dependency order:** Tasks 1-4 (events) can be done first. Task 5 (WebSocket) depends on events. Tasks 6-7 (idempotency) are independent of events. Tasks 8-10 (bug fixes) are independent. Tasks 11-12 (E2E) depend on 1-7. Tasks 13-14 depend on 5 and 7 respectively.

**Parallelizable groups:**
- Group A: Tasks 1-4 (events system)
- Group B: Tasks 6-7 (idempotency) -- can run in parallel with Group A
- Group C: Tasks 8-10 (bug fixes) -- can run in parallel with Groups A and B
- Then: Task 5 (WebSocket, needs events)
- Then: Tasks 11-14 (integration, needs everything above)
