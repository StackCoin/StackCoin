# LiveView Homepage Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the static homepage with LiveView-powered pages showing users sorted by activity, with real-time transaction updates.

**Architecture:** Two LiveView modules (`HomeLive`, `UserLive`) in a public `live_session`. Real-time updates via a new `"transactions"` PubSub topic broadcast from `Bank.transfer_between_users/4`. Filter tabs via URL query params and `handle_params`.

**Tech Stack:** Elixir/Phoenix 1.7, Phoenix LiveView, Ecto (SQLite3), Tailwind CSS, Phoenix PubSub

**Design doc:** `docs/plans/2026-03-14-liveview-homepage-design.md`

---

### Task 1: Enable LiveView JS Client

**Files:**
- Modify: `assets/js/app.js` (lines 21-43 are commented out)

**Step 1: Uncomment the LiveView JS setup**

Replace the entire file contents with:

```javascript
// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken}
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
```

**Step 2: Verify the app compiles**

Run: `mix compile`
Expected: Compilation succeeds (JS changes don't affect Elixir compilation, but verify no issues)

**Step 3: Commit**

```bash
git add assets/js/app.js
git commit -m "Enable LiveView JS client"
```

---

### Task 2: Add Data Query — Users by Last Activity

**Files:**
- Modify: `lib/stackcoin/core/user.ex` (add new function after existing `search_users/1` at line 255)

**Step 1: Add `list_users_by_last_activity/1` to `StackCoin.Core.User`**

Add the following function after the `search_users/1` function (after line 255 in `user.ex`):

```elixir
@doc """
Lists users sorted by their most recent transaction time (as sender or receiver).
Filter options: :all (default), :users (non-bots only), :bots (bots only).
"""
def list_users_by_last_activity(filter \\ :all) do
  base_query =
    from(u in Schema.User,
      left_join: t in Schema.Transaction,
      on: t.from_id == u.id or t.to_id == u.id,
      left_join: b in Schema.BotUser,
      on: b.user_id == u.id,
      group_by: [u.id],
      select: %{
        id: u.id,
        username: u.username,
        balance: u.balance,
        is_bot: not is_nil(b.id),
        last_active: max(t.time)
      },
      order_by: [desc_nulls_last: max(t.time)]
    )

  query =
    case filter do
      :bots -> from([u, t, b] in base_query, where: not is_nil(b.id))
      :users -> from([u, t, b] in base_query, where: is_nil(b.id))
      _ -> base_query
    end

  {:ok, Repo.all(query)}
end
```

**Step 2: Test in IEx**

Run: `iex -S mix`
Then: `StackCoin.Core.User.list_users_by_last_activity()`
Expected: Returns `{:ok, [%{id: _, username: _, balance: _, is_bot: _, last_active: _}, ...]}` sorted by last_active descending, with nil last_active values at the end.

Also test filters:
- `StackCoin.Core.User.list_users_by_last_activity(:bots)` — only bot users
- `StackCoin.Core.User.list_users_by_last_activity(:users)` — only non-bot users

**Step 3: Commit**

```bash
git add lib/stackcoin/core/user.ex
git commit -m "Add list_users_by_last_activity query"
```

---

### Task 3: Add Data Query — User Detail with Bot Info

**Files:**
- Modify: `lib/stackcoin/core/user.ex` (add new function after the one from Task 2)

**Step 1: Add `get_user_detail/1` to `StackCoin.Core.User`**

Add after the function from Task 2:

```elixir
@doc """
Gets full user detail including bot info (if applicable) and owner username.
"""
def get_user_detail(user_id) do
  query =
    from(u in Schema.User,
      left_join: b in Schema.BotUser,
      on: b.user_id == u.id,
      left_join: owner in Schema.User,
      on: b.owner_id == owner.id,
      where: u.id == ^user_id,
      select: %{
        id: u.id,
        username: u.username,
        balance: u.balance,
        is_bot: not is_nil(b.id),
        bot_name: b.name,
        owner_id: b.owner_id,
        owner_username: owner.username
      }
    )

  case Repo.one(query) do
    nil -> {:error, :user_not_found}
    user -> {:ok, user}
  end
end
```

**Step 2: Test in IEx**

Run: `iex -S mix`
Then: `StackCoin.Core.User.get_user_detail(1)` (the reserve user)
Expected: Returns `{:ok, %{id: 1, username: "StackCoin Reserve System", balance: _, is_bot: false, bot_name: nil, owner_id: nil, owner_username: nil}}`

If you have a bot user, test with its ID too to verify bot fields are populated.

**Step 3: Commit**

```bash
git add lib/stackcoin/core/user.ex
git commit -m "Add get_user_detail query with bot info"
```

---

### Task 4: Add Data Query — User Transactions

**Files:**
- Modify: `lib/stackcoin/core/bank.ex` (reuse existing `search_transactions/1` — this already supports `:includes_user_id`)

No new code needed. The existing `Bank.search_transactions(includes_user_id: user_id, limit: 20)` already returns transactions involving a specific user, sorted by time descending, with usernames joined.

**Step 1: Verify in IEx**

Run: `iex -S mix`
Then: `StackCoin.Core.Bank.search_transactions(includes_user_id: 1, limit: 20)`
Expected: Returns `{:ok, %{transactions: [...], total_count: _}}` with transactions involving user 1.

**Step 2: No commit needed** — existing functionality.

---

### Task 5: Add PubSub Broadcast for Transactions

**Files:**
- Modify: `lib/stackcoin/core/bank.ex` (lines 35-47, inside `transfer_between_users/4`)

**Step 1: Add PubSub broadcast after successful transfer**

In `bank.ex`, inside the `case result do` block at line 35, add a PubSub broadcast right after line 36 (`{:ok, transaction} ->`), before the event creation loop:

Find this block (lines 35-47):
```elixir
    case result do
      {:ok, transaction} ->
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
```

Replace with:
```elixir
    case result do
      {:ok, transaction} ->
        # Broadcast to global topic for LiveView real-time updates
        Phoenix.PubSub.broadcast(
          StackCoin.PubSub,
          "transactions",
          {:new_transaction, transaction}
        )

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
```

**Step 2: Verify compilation**

Run: `mix compile`
Expected: Compiles without errors.

**Step 3: Commit**

```bash
git add lib/stackcoin/core/bank.ex
git commit -m "Add PubSub broadcast on transactions topic"
```

---

### Task 6: Update Router — Replace Controller with LiveView Routes

**Files:**
- Modify: `lib/stackcoin_web/router.ex` (lines 24-30)

**Step 1: Replace the browser scope with LiveView routes**

Find this block (lines 24-30):
```elixir
  scope "/" do
    pipe_through(:browser)

    get("/", StackCoinWeb.PageController, :home)

    get("/swaggerui", OpenApiSpex.Plug.SwaggerUI, @swagger_ui_config)
  end
```

Replace with:
```elixir
  scope "/" do
    pipe_through(:browser)

    get("/swaggerui", OpenApiSpex.Plug.SwaggerUI, @swagger_ui_config)
  end

  live_session :default, layout: {StackCoinWeb.Layouts, :app} do
    scope "/" do
      pipe_through(:browser)

      live("/", StackCoinWeb.HomeLive, :index)
      live("/user/:id", StackCoinWeb.UserLive, :show)
    end
  end
```

Note: `swaggerui` stays as a regular `get` route (not a LiveView). The `live_session` wraps only the LiveView routes.

**Step 2: Verify compilation (will warn about missing modules, that's expected)**

Run: `mix compile`
Expected: Warnings about `StackCoinWeb.HomeLive` and `StackCoinWeb.UserLive` not being defined. That's fine — we'll create them next.

**Step 3: Commit**

```bash
git add lib/stackcoin_web/router.ex
git commit -m "Replace controller homepage route with LiveView routes"
```

---

### Task 7: Create HomeLive — Users List with Filters and Real-Time Updates

**Files:**
- Create: `lib/stackcoin_web/live/home_live.ex`

**Step 1: Create the `lib/stackcoin_web/live/` directory**

```bash
mkdir -p lib/stackcoin_web/live
```

**Step 2: Create `HomeLive` module**

Create `lib/stackcoin_web/live/home_live.ex`:

```elixir
defmodule StackCoinWeb.HomeLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.User

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = parse_filter(params["filter"])

    {:ok, users} = User.list_users_by_last_activity(filter)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:users, users)
     |> assign(:page_title, "StackCoin")}
  end

  @impl true
  def handle_info({:new_transaction, _transaction}, socket) do
    {:ok, users} = User.list_users_by_last_activity(socket.assigns.filter)
    {:noreply, assign(socket, :users, users)}
  end

  defp parse_filter("bots"), do: :bots
  defp parse_filter("users"), do: :users
  defp parse_filter(_), do: :all

  defp time_ago(nil), do: "never"

  defp time_ago(naive_datetime) do
    now = NaiveDateTime.utc_now()
    diff = NaiveDateTime.diff(now, naive_datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <nav class="flex gap-6 mb-6 border-b border-gray-200">
        <.link
          patch={~p"/"}
          class={[
            "pb-2 text-sm",
            @filter == :all && "border-b-2 border-black font-bold"
          ]}
        >
          All
        </.link>
        <.link
          patch={~p"/?filter=users"}
          class={[
            "pb-2 text-sm",
            @filter == :users && "border-b-2 border-black font-bold"
          ]}
        >
          Users
        </.link>
        <.link
          patch={~p"/?filter=bots"}
          class={[
            "pb-2 text-sm",
            @filter == :bots && "border-b-2 border-black font-bold"
          ]}
        >
          Bots
        </.link>
      </nav>

      <div class="border border-gray-200">
        <div
          :for={user <- @users}
          class="flex items-center justify-between px-4 py-3 border-b border-gray-200 last:border-b-0"
        >
          <.link navigate={~p"/user/#{user.id}"} class="flex items-center gap-2 no-underline">
            <span class="font-medium text-gray-900">{user.username}</span>
            <span
              :if={user.is_bot}
              class="text-xs uppercase tracking-wide text-gray-500 border border-gray-300 px-1"
            >
              BOT
            </span>
          </.link>
          <div class="flex items-center gap-4">
            <span class="font-mono text-sm">{user.balance} STK</span>
            <span class="text-sm text-gray-500 w-16 text-right">{time_ago(user.last_active)}</span>
          </div>
        </div>

        <div :if={@users == []} class="px-4 py-8 text-center text-gray-500">
          No users found.
        </div>
      </div>
    </div>
    """
  end
end
```

**Step 3: Verify compilation**

Run: `mix compile`
Expected: Compiles. May warn about `StackCoinWeb.UserLive` not existing yet.

**Step 4: Commit**

```bash
git add lib/stackcoin_web/live/home_live.ex
git commit -m "Add HomeLive with users list, filter tabs, and real-time updates"
```

---

### Task 8: Create UserLive — User Detail Page

**Files:**
- Create: `lib/stackcoin_web/live/user_live.ex`

**Step 1: Create `UserLive` module**

Create `lib/stackcoin_web/live/user_live.ex`:

```elixir
defmodule StackCoinWeb.UserLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.{User, Bank}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case load_user_data(id) do
      {:ok, user, transactions} ->
        {:noreply,
         socket
         |> assign(:user, user)
         |> assign(:transactions, transactions)
         |> assign(:page_title, "#{user.username} — StackCoin")}

      {:error, :user_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "User not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:new_transaction, _transaction}, socket) do
    user_id = socket.assigns.user.id

    case load_user_data(user_id) do
      {:ok, user, transactions} ->
        {:noreply,
         socket
         |> assign(:user, user)
         |> assign(:transactions, transactions)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp load_user_data(user_id) do
    with {:ok, user} <- User.get_user_detail(user_id),
         {:ok, %{transactions: transactions}} <-
           Bank.search_transactions(includes_user_id: user_id, limit: 20) do
      {:ok, user, transactions}
    end
  end

  defp time_ago(nil), do: "never"

  defp time_ago(naive_datetime) do
    now = NaiveDateTime.utc_now()
    diff = NaiveDateTime.diff(now, naive_datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>

      <div class="mb-6">
        <h1 class="text-2xl font-bold flex items-center gap-2">
          {@user.username}
          <span
            :if={@user.is_bot}
            class="text-xs uppercase tracking-wide text-gray-500 border border-gray-300 px-1 font-normal"
          >
            BOT
          </span>
        </h1>
        <p class="text-lg font-mono mt-1">{@user.balance} STK</p>
        <p :if={@user.is_bot && @user.owner_username} class="text-sm text-gray-500 mt-1">
          Owned by:
          <.link navigate={~p"/user/#{@user.owner_id}"}>
            {@user.owner_username}
          </.link>
        </p>
      </div>

      <h2 class="text-lg font-bold mb-3">Recent Transactions</h2>

      <div class="border border-gray-200">
        <div
          :for={tx <- @transactions}
          class="flex items-center justify-between px-4 py-3 border-b border-gray-200 last:border-b-0"
        >
          <div class="flex items-center gap-2">
            <span class="font-mono text-sm font-bold">{tx.amount} STK</span>
            <span class="text-sm">
              <.link navigate={~p"/user/#{tx.from_id}"}>{tx.from_username}</.link>
              &rarr;
              <.link navigate={~p"/user/#{tx.to_id}"}>{tx.to_username}</.link>
            </span>
          </div>
          <span class="text-sm text-gray-500">{time_ago(tx.time)}</span>
        </div>

        <div :if={@transactions == []} class="px-4 py-8 text-center text-gray-500">
          No transactions yet.
        </div>
      </div>
    </div>
    """
  end
end
```

**Step 2: Verify compilation**

Run: `mix compile`
Expected: Compiles without errors or warnings (both LiveView modules now exist).

**Step 3: Commit**

```bash
git add lib/stackcoin_web/live/user_live.ex
git commit -m "Add UserLive with user detail, transactions, and real-time updates"
```

---

### Task 9: Manual Smoke Test

**Step 1: Start the server**

Run: `mix phx.server`

**Step 2: Test the homepage**

Open `http://localhost:4000/` in a browser.
Expected:
- See the StackCoin logo header
- See filter tabs: All, Users, Bots
- See a list of users sorted by last activity (most recent transaction first)
- Each user shows username, balance, and relative time
- Bot users show a [BOT] tag
- Clicking a filter tab updates the URL and filters the list without a full page reload

**Step 3: Test the user detail page**

Click on a username in the list.
Expected:
- Navigates to `/user/:id`
- Shows the user's name, balance
- If bot: shows bot tag and owner link
- Shows recent transactions involving that user
- Back link returns to homepage

**Step 4: Test real-time updates**

If you can trigger a transaction (via Discord or the API), verify that:
- The homepage re-sorts users when a new transaction happens
- The user detail page shows the new transaction at the top

**Step 5: Verify no broken pages**

- `http://localhost:4000/swaggerui` still works
- `http://localhost:4000/dev/dashboard` still works

**Step 6: Commit (if any fixes were needed)**

```bash
git add -A
git commit -m "Fix any issues found during smoke testing"
```

---

### Task 10: Clean Up Old Controller Files

**Files:**
- Delete: `lib/stackcoin_web/controllers/page_controller.ex`
- Delete: `lib/stackcoin_web/controllers/page_html.ex` (if it exists)
- Delete: `lib/stackcoin_web/controllers/page_html/home.html.heex`

**Step 1: Remove the old page controller and template**

```bash
rm lib/stackcoin_web/controllers/page_controller.ex
rm -rf lib/stackcoin_web/controllers/page_html/
rm -f lib/stackcoin_web/controllers/page_html.ex
```

**Step 2: Verify compilation**

Run: `mix compile`
Expected: Compiles without errors. No references to `PageController` should remain (the router no longer references it after Task 6).

**Step 3: Commit**

```bash
git add -A
git commit -m "Remove old PageController and templates replaced by LiveView"
```
