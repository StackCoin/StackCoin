# LiveView Feature Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the web UI to feature parity with the Discord bot — bot management, preauthorization management, admin tools, balance graph time ranges, and directional transaction filtering.

**Architecture:** Six independent feature areas implemented as new LiveView pages (bots, preauths, admin) plus enhancements to existing pages (user profile graph, transactions filter). Each page follows the existing patterns: `max-w-2xl mx-auto px-4 py-6 w-full` container, border-only buttons, card-based rows, filter tabs with `patch`, flash messages. A JS hook handles clipboard copy for bot tokens.

**Tech Stack:** Elixir/Phoenix LiveView, Tailwind CSS, JavaScript hooks, PubSub

---

## File Structure

### New Files
- `lib/stackcoin_web/live/bots_live.ex` — bot management page (create, list, token reveal, reset, delete)
- `lib/stackcoin_web/live/preauths_live.ex` — preauthorization list and revoke
- `lib/stackcoin_web/live/admin_live.ex` — admin panel (pump, ban/unban, dole-ban/unban)
- `assets/js/hooks/clipboard.js` — JS hook for copy-to-clipboard
- `test/stackcoin_web/live/bots_live_test.exs` — bot management tests
- `test/stackcoin_web/live/preauths_live_test.exs` — preauth page tests
- `test/stackcoin_web/live/admin_live_test.exs` — admin panel tests

### Modified Files
- `lib/stackcoin_web/live/user_auth_hook.ex` — add `is_admin` assign
- `lib/stackcoin_web/components/layouts/app.html.heex` — add nav bar with conditional links
- `lib/stackcoin_web/router.ex` — add 3 new routes
- `lib/stackcoin/bot/discord/bot.ex` — extract `send_bot_creation_request_dm/2` and `send_bot_token_dm/2` as public functions
- `lib/stackcoin/core/preauthorization.ex` — add PubSub broadcasts on approve/revoke
- `lib/stackcoin_web/controllers/graph_controller.ex` — accept `range` query param
- `lib/stackcoin/graph_cache.ex` — pass `since` through to generation
- `lib/stackcoin_web/live/user_live.ex` — add time range tabs above graph
- `lib/stackcoin_web/live/transactions_live.ex` — add direction filter select
- `assets/js/app.js` — register Clipboard hook
- `test/stackcoin_web/live/user_live_test.exs` — time range tab tests
- `test/stackcoin_web/live/transactions_live_test.exs` — direction filter tests

---

### Task 1: Foundation — UserAuthHook `is_admin` assign, nav bar, routes

**Files:**
- Modify: `lib/stackcoin_web/live/user_auth_hook.ex`
- Modify: `lib/stackcoin_web/components/layouts/app.html.heex`
- Modify: `lib/stackcoin_web/router.ex`

- [ ] **Step 1: Add `is_admin` assign to UserAuthHook**

In `lib/stackcoin_web/live/user_auth_hook.ex`, replace the entire module:

```elixir
defmodule StackCoinWeb.Live.UserAuthHook do
  @moduledoc """
  LiveView on_mount hook that loads current_user from the session.
  """
  import Phoenix.Component, only: [assign: 3]

  alias StackCoin.Core.User

  def on_mount(:default, _params, session, socket) do
    user_id = session["user_id"]

    {current_user, is_admin} =
      if user_id do
        case User.get_user_by_id(user_id) do
          {:ok, user} ->
            admin =
              user.admin ||
                (user.discord_snowflake != nil &&
                   to_string(user.discord_snowflake) ==
                     Application.get_env(:stackcoin, :admin_user_id))

            {user, admin}

          _ ->
            {nil, false}
        end
      else
        {nil, false}
      end

    {:cont,
     socket
     |> assign(:current_user, current_user)
     |> assign(:is_admin, is_admin)}
  end
end
```

Wait — the user schema may not have `discord_snowflake` directly. We need to check how to get the discord snowflake from the user. Let me look at `User.get_user_by_id` to see what it returns vs `get_user_detail`.

Actually, looking at the user schema, the discord snowflake is on the `discord_user` association, not the user directly. The simpler approach: just use `User.is_user_admin?/1` which takes a discord snowflake. But we need the snowflake from the user record.

Simpler approach — check the `admin` column directly (it's on the User schema) AND check against config. The `admin` column is set to `true` when the admin first runs a command that triggers `ensure_admin_user_exists`. For the config check, we need the discord snowflake.

Let's look at how to get it. The User has `has_one :discord_user` which has a `snowflake` field. We can preload it. But `get_user_by_id` may not preload it.

Safest approach: just check `user.admin` column. If the admin has ever used any admin command via Discord, this column is already true. For a fresh DB where admin has only logged in via OAuth but never used a Discord command, we should also check the session — the OAuth flow stores the discord user ID.

Even simpler: the admin column check is sufficient for the nav bar. If it's not set, the admin link won't show, but the admin can still navigate to `/admin` directly and the page itself will do a full permissions check. This is acceptable — once the admin uses any admin feature, the column gets set.

Let's go with just `user.admin`:

```elixir
defmodule StackCoinWeb.Live.UserAuthHook do
  @moduledoc """
  LiveView on_mount hook that loads current_user from the session.
  """
  import Phoenix.Component, only: [assign: 3]

  alias StackCoin.Core.User

  def on_mount(:default, _params, session, socket) do
    user_id = session["user_id"]

    current_user =
      if user_id do
        case User.get_user_by_id(user_id) do
          {:ok, user} -> user
          _ -> nil
        end
      end

    is_admin =
      if current_user do
        current_user.admin == true
      else
        false
      end

    {:cont,
     socket
     |> assign(:current_user, current_user)
     |> assign(:is_admin, is_admin)}
  end
end
```

- [ ] **Step 2: Add nav bar to app layout**

In `lib/stackcoin_web/components/layouts/app.html.heex`, replace the full file:

```heex
<header class="w-full py-4">
  <div class="flex items-center justify-center">
    <img src={~p"/images/stackcoin.png"} class="w-64" />
  </div>
  <div class="text-center mt-2 text-sm">
    <%= if assigns[:current_user] do %>
      <span class="text-gray-500">
        {@current_user.username}
      </span>
      <span class="text-gray-300 mx-1">&middot;</span>
      <a href="/auth/logout" class="text-gray-500">Logout</a>
    <% else %>
      <a href="/auth/discord" class="text-gray-500">Login with Discord</a>
    <% end %>
  </div>
  <%= if assigns[:current_user] do %>
    <nav class="flex items-center justify-center gap-4 mt-2 text-sm">
      <.link navigate={~p"/bots"} class="text-gray-500">Bots</.link>
      <.link navigate={~p"/preauths"} class="text-gray-500">Preauths</.link>
      <.link :if={assigns[:is_admin]} navigate={~p"/admin"} class="text-gray-500">
        Admin
      </.link>
    </nav>
  <% end %>
</header>

<main class="flex-1 flex flex-col">
  <.flash_group flash={@flash} />
  {@inner_content}
</main>

<footer class="text-center pb-4 flex items-center justify-center gap-4">
  <a href="/swaggerui">OpenAPI Documentation</a>
  <a href="https://github.com/stackcoin/stackcoin">Source Code</a>
</footer>
```

- [ ] **Step 3: Add routes**

In `lib/stackcoin_web/router.ex`, inside the `live_session :default` block, add after the existing `live("/user/:id", ...)` line:

```elixir
      live("/bots", StackCoinWeb.BotsLive, :index)
      live("/preauths", StackCoinWeb.PreauthsLive, :index)
      live("/admin", StackCoinWeb.AdminLive, :index)
```

- [ ] **Step 4: Create placeholder LiveView modules so the app compiles**

Create `lib/stackcoin_web/live/bots_live.ex`:

```elixir
defmodule StackCoinWeb.BotsLive do
  use StackCoinWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    if socket.assigns[:current_user] == nil do
      {:noreply,
       socket
       |> put_flash(:error, "You must be logged in to manage bots.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply, assign(socket, :page_title, "Bots — StackCoin")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>
      <h1 class="text-2xl font-bold mb-4">Bots</h1>
      <p class="text-gray-500">Coming soon.</p>
    </div>
    """
  end
end
```

Create `lib/stackcoin_web/live/preauths_live.ex`:

```elixir
defmodule StackCoinWeb.PreauthsLive do
  use StackCoinWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    if socket.assigns[:current_user] == nil do
      {:noreply,
       socket
       |> put_flash(:error, "You must be logged in to view preauthorizations.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply, assign(socket, :page_title, "Preauthorizations — StackCoin")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>
      <h1 class="text-2xl font-bold mb-4">Preauthorizations</h1>
      <p class="text-gray-500">Coming soon.</p>
    </div>
    """
  end
end
```

Create `lib/stackcoin_web/live/admin_live.ex`:

```elixir
defmodule StackCoinWeb.AdminLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.User

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    current_user = socket.assigns[:current_user]

    cond do
      current_user == nil ->
        {:noreply,
         socket
         |> put_flash(:error, "You must be logged in.")
         |> push_navigate(to: ~p"/")}

      !socket.assigns[:is_admin] ->
        {:noreply,
         socket
         |> put_flash(:error, "Admin access required.")
         |> push_navigate(to: ~p"/")}

      true ->
        {:noreply, assign(socket, :page_title, "Admin — StackCoin")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>
      <h1 class="text-2xl font-bold mb-4">Admin</h1>
      <p class="text-gray-500">Coming soon.</p>
    </div>
    """
  end
end
```

- [ ] **Step 5: Verify it compiles and existing tests pass**

Run: `mix compile --warnings-as-errors && mix test`
Expected: compiles cleanly, all 400 tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: add nav bar, routes, and placeholder pages for bots/preauths/admin"
```

---

### Task 2: Extract Discord bot DM helpers as public functions

**Files:**
- Modify: `lib/stackcoin/bot/discord/bot.ex`

The LiveView bot management page needs to call `send_bot_token_dm` and `send_bot_creation_request_dm`. These are currently `defp` in the Discord bot module. Make them public and extract the DM-only logic.

- [ ] **Step 1: Make `send_bot_token_dm/2` public**

In `lib/stackcoin/bot/discord/bot.ex`, change line 499 from:

```elixir
  defp send_bot_token_dm(user_id, bot) do
```

to:

```elixir
  @doc """
  Sends a DM to the given Discord user ID with the bot's token.
  Called from both the Discord bot and the web UI.
  """
  def send_bot_token_dm(user_id, bot) do
```

- [ ] **Step 2: Extract `send_bot_creation_request_dm/2` from `send_bot_creation_request/2`**

Add a new public function right after the existing `send_bot_creation_request/2` (which stays as-is for the Discord bot to call). The new function only sends the admin DM — no channel reply:

```elixir
  @doc """
  Sends a DM to the admin with Accept/Reject buttons for a bot creation request.
  Called from both the Discord bot and the web UI.
  Returns :ok or :error.
  """
  def send_bot_creation_request_dm(requester_snowflake, bot_name) do
    requester_display =
      case StackCoin.Core.User.get_user_by_discord_id(requester_snowflake) do
        {:ok, user} -> user.username
        _ -> "#{requester_snowflake}"
      end

    admin_user_id_str = Application.get_env(:stackcoin, :admin_user_id)

    if admin_user_id_str do
      admin_user_id =
        if is_binary(admin_user_id_str),
          do: String.to_integer(admin_user_id_str),
          else: admin_user_id_str

      case Api.User.create_dm(admin_user_id) do
        {:ok, dm_channel} ->
          Api.Message.create(dm_channel.id, %{
            flags: Components.is_components_v2_flag(),
            components: [
              %{
                type: Components.container(),
                accent_color: Commands.stackcoin_color(),
                components: [
                  %{
                    type: Components.text_display(),
                    content:
                      "#{Commands.stackcoin_emoji()} Bot Creation Request\n\n**#{requester_display}** (<@#{requester_snowflake}>) is requesting to create a bot named **#{bot_name}**.\n\nRequester: #{requester_display}\nBot Name: #{bot_name}"
                  },
                  %{
                    type: Components.action_row(),
                    components: [
                      %{
                        type: Components.button(),
                        style: Components.button_style_success(),
                        label: "Accept",
                        custom_id: "bot_create_accept:#{requester_snowflake}:#{bot_name}"
                      },
                      %{
                        type: Components.button(),
                        style: Components.button_style_danger(),
                        label: "Reject",
                        custom_id: "bot_create_reject:#{requester_snowflake}:#{bot_name}"
                      }
                    ]
                  }
                ]
              }
            ]
          })

          :ok

        {:error, reason} ->
          Logger.error(
            "Failed to DM admin for bot creation request '#{bot_name}': #{inspect(reason)}"
          )

          :error
      end
    else
      :error
    end
  end
```

- [ ] **Step 3: Update `send_bot_creation_request/2` to delegate to the new function**

Replace the DM-sending portion of the existing `send_bot_creation_request/2` (everything after the channel reply, lines 336-388) with a call to the new function:

```elixir
    # DM the admin with Accept/Reject buttons
    send_bot_creation_request_dm(requester_snowflake, bot_name)
```

- [ ] **Step 4: Verify existing tests still pass**

Run: `mix test`
Expected: all 400 tests pass (no behavioral change, just refactoring private to public + delegation).

- [ ] **Step 5: Commit**

```bash
git add lib/stackcoin/bot/discord/bot.ex && git commit -m "refactor: extract bot DM helpers as public functions for web UI reuse"
```

---

### Task 3: Clipboard JS hook

**Files:**
- Create: `assets/js/hooks/clipboard.js`
- Modify: `assets/js/app.js`

- [ ] **Step 1: Create the Clipboard hook**

Create `assets/js/hooks/clipboard.js`:

```javascript
const Clipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.clipboardText
      if (text) {
        navigator.clipboard.writeText(text).then(() => {
          const original = this.el.innerText
          this.el.innerText = "Copied!"
          setTimeout(() => { this.el.innerText = original }, 1500)
        })
      }
    })
  }
}

export default Clipboard
```

- [ ] **Step 2: Register the hook in app.js**

In `assets/js/app.js`, add after the existing `import NetworkGraph` line:

```javascript
import Clipboard from "./hooks/clipboard"
```

Change the Hooks line from:

```javascript
let Hooks = {NetworkGraph}
```

to:

```javascript
let Hooks = {NetworkGraph, Clipboard}
```

- [ ] **Step 3: Verify the app compiles**

Run: `mix compile`
Expected: compiles cleanly.

- [ ] **Step 4: Commit**

```bash
git add assets/js/hooks/clipboard.js assets/js/app.js && git commit -m "feat: add Clipboard JS hook for copy-to-clipboard"
```

---

### Task 4: Bot Management Page (`/bots`)

**Files:**
- Modify: `lib/stackcoin_web/live/bots_live.ex` (replace placeholder)
- Create: `test/stackcoin_web/live/bots_live_test.exs`

- [ ] **Step 1: Write the tests**

Create `test/stackcoin_web/live/bots_live_test.exs`:

```elixir
defmodule StackCoinWebTest.BotsLiveTest do
  use StackCoinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias StackCoin.Core.{User, Bot, Bank}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 10_000)
    {:ok, alice} = User.create_user_account("alice_discord", "alice", balance: 0)

    # Make alice admin for admin tests
    {:ok, admin} = User.create_user_account("admin_discord", "admin", balance: 0, admin: true)

    # Give admin a bot
    {:ok, bot} = Bot.create_bot_user("admin_discord", "TestBot")

    %{alice: alice, admin: admin, bot: bot}
  end

  defp login(conn, user) do
    conn |> Plug.Test.init_test_session(%{user_id: user.id})
  end

  describe "auth guard" do
    test "redirects to / when not logged in", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => _}}}} =
               live(conn, ~p"/bots")
    end
  end

  describe "authenticated access" do
    test "renders page with create form", %{conn: conn, admin: admin} do
      {:ok, _view, html} = conn |> login(admin) |> live(~p"/bots")

      assert html =~ "Bots"
      assert html =~ "Create Bot"
    end

    test "lists user's bots", %{conn: conn, admin: admin, bot: bot} do
      {:ok, _view, html} = conn |> login(admin) |> live(~p"/bots")

      assert html =~ bot.name
    end

    test "shows empty state when user has no bots", %{conn: conn, alice: alice} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/bots")

      assert html =~ "You don&#39;t have any bots yet."
    end

    test "admin can create a bot", %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/bots")

      html =
        view
        |> form("form[phx-submit=create_bot]", %{name: "NewBot"})
        |> render_submit()

      assert html =~ "NewBot"
      assert html =~ "Token"
    end

    test "delete bot works", %{conn: conn, admin: admin, bot: bot} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/bots")

      html = render_click(view, "delete_bot", %{"bot-id" => to_string(bot.user_id)})

      assert html =~ "Bot deleted"
      refute html =~ bot.name
    end

    test "reset token works", %{conn: conn, admin: admin, bot: bot} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/bots")

      html = render_click(view, "reset_token", %{"bot-id" => to_string(bot.user_id)})

      assert html =~ "Token reset"
      assert html =~ "Token"
    end

    test "token reveal toggle works", %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/bots")

      # Create a bot to get a token
      view
      |> form("form[phx-submit=create_bot]", %{name: "RevealBot"})
      |> render_submit()

      # Token should be hidden initially
      html = render(view)
      assert html =~ "••••••••"

      # Find the bot's user_id for the toggle
      {:ok, bots} = Bot.get_user_bots("admin_discord")
      reveal_bot = Enum.find(bots, &(&1.name == "RevealBot"))

      # Toggle reveal
      html = render_click(view, "toggle_token", %{"bot-id" => to_string(reveal_bot.user_id)})
      refute html =~ "••••••••"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/stackcoin_web/live/bots_live_test.exs`
Expected: failures (placeholder page has no create form, no bot list, no event handlers).

- [ ] **Step 3: Implement BotsLive**

Replace `lib/stackcoin_web/live/bots_live.ex` with:

```elixir
defmodule StackCoinWeb.BotsLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.{Bot, Bank}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
    end

    {:ok, assign(socket, revealed_tokens: %{}, show_tokens: MapSet.new())}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    current_user = socket.assigns[:current_user]

    if current_user == nil do
      {:noreply,
       socket
       |> put_flash(:error, "You must be logged in to manage bots.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply,
       socket
       |> load_bots()
       |> assign(:page_title, "Bots — StackCoin")}
    end
  end

  @impl true
  def handle_event("create_bot", %{"name" => name}, socket) do
    current_user = socket.assigns.current_user
    discord_snowflake = get_discord_snowflake(current_user)

    case Bot.admin_create_bot_user(discord_snowflake, name) do
      {:ok, {_bot_user, token}} ->
        # Reload bots to get the new one
        socket = load_bots(socket)
        # Find the bot we just created to get its user_id
        bot = Enum.find(socket.assigns.bots, &(&1.name == name))

        revealed =
          if bot,
            do: Map.put(socket.assigns.revealed_tokens, bot.user_id, token),
            else: socket.assigns.revealed_tokens

        # DM the token via Discord (best effort)
        if discord_snowflake do
          try do
            StackCoin.Bot.Discord.Bot.send_bot_token_dm(
              String.to_integer(discord_snowflake),
              %{name: name, token: token}
            )
          rescue
            _ -> :ok
          end
        end

        {:noreply,
         socket
         |> assign(:revealed_tokens, revealed)
         |> put_flash(:info, "Bot \"#{name}\" created.")}

      {:error, :not_admin} ->
        # Non-admin: send request to admin via Discord DM
        if discord_snowflake do
          try do
            StackCoin.Bot.Discord.Bot.send_bot_creation_request_dm(
              String.to_integer(discord_snowflake),
              name
            )
          rescue
            _ -> :ok
          end
        end

        {:noreply, put_flash(socket, :info, "Bot creation request sent to admin for approval.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("reset_token", %{"bot-id" => bot_id_str}, socket) do
    current_user = socket.assigns.current_user
    discord_snowflake = get_discord_snowflake(current_user)
    bot_id = String.to_integer(bot_id_str)

    case Bot.reset_bot_token(discord_snowflake, bot_id) do
      {:ok, updated_bot} ->
        revealed = Map.put(socket.assigns.revealed_tokens, bot_id, updated_bot.token)

        # DM the new token via Discord (best effort)
        if discord_snowflake do
          try do
            StackCoin.Bot.Discord.Bot.send_bot_token_dm(
              String.to_integer(discord_snowflake),
              updated_bot
            )
          rescue
            _ -> :ok
          end
        end

        {:noreply,
         socket
         |> assign(:revealed_tokens, revealed)
         |> put_flash(:info, "Token reset.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("delete_bot", %{"bot-id" => bot_id_str}, socket) do
    current_user = socket.assigns.current_user
    discord_snowflake = get_discord_snowflake(current_user)
    bot_id = String.to_integer(bot_id_str)

    case Bot.delete_bot_user(discord_snowflake, bot_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_bots()
         |> put_flash(:info, "Bot deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("toggle_token", %{"bot-id" => bot_id_str}, socket) do
    bot_id = String.to_integer(bot_id_str)
    show = socket.assigns.show_tokens

    show =
      if MapSet.member?(show, bot_id),
        do: MapSet.delete(show, bot_id),
        else: MapSet.put(show, bot_id)

    {:noreply, assign(socket, :show_tokens, show)}
  end

  @impl true
  def handle_info({:new_transaction, _transaction}, socket) do
    if socket.assigns[:current_user] do
      {:noreply, load_bots(socket)}
    else
      {:noreply, socket}
    end
  end

  defp load_bots(socket) do
    current_user = socket.assigns.current_user
    discord_snowflake = get_discord_snowflake(current_user)

    bots =
      case Bot.get_user_bots(discord_snowflake) do
        {:ok, bots} -> bots
        _ -> []
      end

    # Enrich with balance
    bots_with_balance =
      Enum.map(bots, fn bot ->
        balance =
          case Bank.get_user_balance(bot.user_id) do
            {:ok, bal} -> bal
            _ -> 0
          end

        Map.put(bot, :balance, balance)
      end)

    assign(socket, :bots, bots_with_balance)
  end

  defp get_discord_snowflake(user) do
    case StackCoin.Repo.preload(user, :discord_user) do
      %{discord_user: %{snowflake: snowflake}} when not is_nil(snowflake) ->
        to_string(snowflake)

      _ ->
        nil
    end
  end

  defp format_error(:not_admin), do: "Admin permission required."
  defp format_error(:not_owner), do: "You don't own this bot."
  defp format_error(:bot_not_found), do: "Bot not found."
  defp format_error(:user_not_found), do: "User not found."
  defp format_error(:name_taken), do: "That bot name is already taken."
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>

      <h1 class="text-2xl font-bold mb-4">Bots</h1>

      <div class="mb-8">
        <h2 class="text-lg font-bold mb-3">Create Bot</h2>
        <form phx-submit="create_bot" class="flex items-center gap-2">
          <input
            type="text"
            name="name"
            placeholder="Bot name"
            required
            class="border border-gray-200 px-3 py-2 text-sm"
          />
          <button type="submit" class="border border-black px-4 py-2 text-sm font-bold">
            Create Bot
          </button>
        </form>
      </div>

      <div class="mb-8">
        <h2 class="text-lg font-bold mb-3">Your Bots</h2>
        <div class="border border-gray-200">
          <div
            :for={bot <- @bots}
            class="px-4 py-3 border-b border-gray-200 last:border-b-0"
          >
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <.link navigate={~p"/user/#{bot.user_id}"}>
                  {bot.name}
                </.link>
                <span class="text-xs uppercase tracking-wide text-gray-500 border border-gray-300 px-1">
                  BOT
                </span>
                <span class="font-mono text-sm">{bot.balance} STK</span>
              </div>
              <div class="flex items-center gap-2">
                <button
                  phx-click="reset_token"
                  phx-value-bot-id={bot.user_id}
                  class="border border-black px-3 py-1 text-xs font-bold"
                >
                  Reset Token
                </button>
                <button
                  phx-click="delete_bot"
                  phx-value-bot-id={bot.user_id}
                  class="border border-gray-300 px-3 py-1 text-xs text-gray-500"
                >
                  Delete
                </button>
              </div>
            </div>
            <%= if Map.has_key?(@revealed_tokens, bot.user_id) do %>
              <div class="mt-2 flex items-center gap-2">
                <span class="text-xs text-gray-500">Token:</span>
                <%= if MapSet.member?(@show_tokens, bot.user_id) do %>
                  <code class="text-xs font-mono bg-gray-50 px-2 py-1 border border-gray-200">
                    {@revealed_tokens[bot.user_id]}
                  </code>
                <% else %>
                  <code class="text-xs font-mono bg-gray-50 px-2 py-1 border border-gray-200">
                    ••••••••
                  </code>
                <% end %>
                <button
                  phx-click="toggle_token"
                  phx-value-bot-id={bot.user_id}
                  class="border border-gray-300 px-2 py-0.5 text-xs text-gray-500"
                >
                  <%= if MapSet.member?(@show_tokens, bot.user_id), do: "Hide", else: "Show" %>
                </button>
                <button
                  id={"copy-token-#{bot.user_id}"}
                  phx-hook="Clipboard"
                  data-clipboard-text={@revealed_tokens[bot.user_id]}
                  class="border border-gray-300 px-2 py-0.5 text-xs text-gray-500"
                >
                  Copy
                </button>
              </div>
            <% end %>
          </div>

          <div :if={@bots == []} class="px-4 py-8 text-center text-gray-500">
            You don't have any bots yet.
          </div>
        </div>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/stackcoin_web/live/bots_live_test.exs --trace`
Expected: all tests pass. If any failures related to `create_user_account` not accepting `admin:` option, adjust setup to set admin via `User.ban_user` pattern or direct Repo update.

- [ ] **Step 5: Fix any test issues**

If `create_user_account` doesn't accept `admin: true`, update the test setup to use:
```elixir
{:ok, admin} = User.create_user_account("admin_discord", "admin", balance: 0)
StackCoin.Repo.update!(Ecto.Changeset.change(admin, admin: true))
```

Also check if `Bot.get_user_bots/1` returns bot structs with a `user_id` field — this is the `BotUser.user_id` (the bot's user account ID). If the field name differs, adjust the template.

- [ ] **Step 6: Run full test suite**

Run: `mix test`
Expected: all tests pass (400+ now).

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: bot management page with create, list, token reveal, reset, delete"
```

---

### Task 5: Preauthorizations Page (`/preauths`)

**Files:**
- Modify: `lib/stackcoin_web/live/preauths_live.ex` (replace placeholder)
- Modify: `lib/stackcoin/core/preauthorization.ex` (add PubSub broadcasts)
- Create: `test/stackcoin_web/live/preauths_live_test.exs`

- [ ] **Step 1: Add PubSub broadcasts to preauthorization core**

In `lib/stackcoin/core/preauthorization.ex`, add this after successful approve in `approve_preauth/1` (inside the `{:ok, preauth}` case):

```elixir
Phoenix.PubSub.broadcast(StackCoin.PubSub, "preauths", {:preauth_approved, preauth})
```

And after successful revoke in `revoke_preauth/1` (inside the `{:ok, preauth}` case):

```elixir
Phoenix.PubSub.broadcast(StackCoin.PubSub, "preauths", {:preauth_revoked, preauth})
```

Find the exact spots: in `approve_preauth/1`, after the `Repo.update` succeeds and returns `{:ok, preauth}`, add the broadcast before returning. Same pattern for `revoke_preauth/1`.

- [ ] **Step 2: Write the tests**

Create `test/stackcoin_web/live/preauths_live_test.exs`:

```elixir
defmodule StackCoinWebTest.PreauthsLiveTest do
  use StackCoinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias StackCoin.Core.{User, Bot, Preauthorization}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 10_000)
    {:ok, alice} = User.create_user_account("alice_discord", "alice", balance: 0)
    {:ok, bot_owner} = User.create_user_account("owner_discord", "BotOwner", balance: 0)
    {:ok, bot} = Bot.create_bot_user("owner_discord", "LuckyBot")

    # Create and approve a preauth for alice
    {:ok, preauth} = Preauthorization.create_preauth(bot.user_id, alice.id, 10, 24)
    {:ok, preauth} = Preauthorization.approve_preauth(preauth.id)

    %{alice: alice, bot_owner: bot_owner, bot: bot, preauth: preauth}
  end

  defp login(conn, user) do
    conn |> Plug.Test.init_test_session(%{user_id: user.id})
  end

  describe "auth guard" do
    test "redirects to / when not logged in", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => _}}}} =
               live(conn, ~p"/preauths")
    end
  end

  describe "authenticated access" do
    test "renders preauth list", %{conn: conn, alice: alice, bot: bot} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/preauths")

      assert html =~ "Preauthorizations"
      assert html =~ bot.name
      assert html =~ "10 STK"
      assert html =~ "24"
    end

    test "shows empty state when no preauths", %{conn: conn, bot_owner: bot_owner} do
      {:ok, _view, html} = conn |> login(bot_owner) |> live(~p"/preauths")

      assert html =~ "No active preauthorizations."
    end

    test "revoke preauth works", %{conn: conn, alice: alice, preauth: preauth} do
      {:ok, view, _html} = conn |> login(alice) |> live(~p"/preauths")

      html = render_click(view, "revoke", %{"id" => to_string(preauth.id)})

      assert html =~ "Preauthorization revoked"
      assert html =~ "No active preauthorizations."
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/stackcoin_web/live/preauths_live_test.exs`
Expected: failures.

- [ ] **Step 4: Implement PreauthsLive**

Replace `lib/stackcoin_web/live/preauths_live.ex`:

```elixir
defmodule StackCoinWeb.PreauthsLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.{Preauthorization, Bot}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "preauths")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    current_user = socket.assigns[:current_user]

    if current_user == nil do
      {:noreply,
       socket
       |> put_flash(:error, "You must be logged in to view preauthorizations.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply,
       socket
       |> load_preauths()
       |> assign(:page_title, "Preauthorizations — StackCoin")}
    end
  end

  @impl true
  def handle_event("revoke", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    case Preauthorization.revoke_preauth(id) do
      {:ok, _preauth} ->
        {:noreply,
         socket
         |> load_preauths()
         |> put_flash(:info, "Preauthorization revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  @impl true
  def handle_info({:preauth_approved, _}, socket) do
    {:noreply, load_preauths(socket)}
  end

  def handle_info({:preauth_revoked, _}, socket) do
    {:noreply, load_preauths(socket)}
  end

  defp load_preauths(socket) do
    current_user = socket.assigns.current_user
    preauths = Preauthorization.list_preauths_for_user(current_user.id)

    preauths_with_info =
      Enum.map(preauths, fn preauth ->
        owner_info =
          case Bot.get_bot_owner_info(preauth.bot_user_id) do
            {:ok, info} -> info
            _ -> nil
          end

        remaining =
          case Preauthorization.get_remaining_budget(preauth.id) do
            {:ok, r} -> r
            _ -> 0
          end

        %{preauth: preauth, owner_info: owner_info, remaining: remaining}
      end)

    assign(socket, :preauths, preauths_with_info)
  end

  defp format_error(:preauth_not_found), do: "Preauthorization not found."
  defp format_error(:already_revoked), do: "Already revoked."
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>

      <h1 class="text-2xl font-bold mb-4">Preauthorizations</h1>

      <div class="border border-gray-200">
        <div
          :for={item <- @preauths}
          class="flex items-center justify-between px-4 py-3 border-b border-gray-200 last:border-b-0"
        >
          <div>
            <div class="flex items-center gap-2">
              <.link navigate={~p"/user/#{item.preauth.bot_user_id}"}>
                {item.preauth.bot_user.user.username}
              </.link>
              <span class="text-xs uppercase tracking-wide text-gray-500 border border-gray-300 px-1">
                BOT
              </span>
              <%= if item.owner_info do %>
                <span class="text-sm text-gray-500">
                  owned by
                  <.link navigate={~p"/user/#{item.owner_info.owner_id}"}>
                    {item.owner_info.owner_username}
                  </.link>
                </span>
              <% end %>
            </div>
            <div class="text-sm text-gray-500 mt-1">
              <span class="font-mono">{item.preauth.max_amount} STK</span>
              / {item.preauth.window_hours} hrs
              &middot;
              <span class="font-mono">{item.remaining} STK</span> remaining
            </div>
          </div>
          <button
            phx-click="revoke"
            phx-value-id={item.preauth.id}
            class="border border-gray-300 px-3 py-1 text-xs text-gray-500"
          >
            Revoke
          </button>
        </div>

        <div :if={@preauths == []} class="px-4 py-8 text-center text-gray-500">
          No active preauthorizations.
        </div>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/stackcoin_web/live/preauths_live_test.exs --trace`
Expected: pass. If the preauth doesn't preload `bot_user.user`, adjust `list_preauths_for_user/1` to add the preload, or do it in the LiveView. Check the actual return shape.

- [ ] **Step 6: Fix preload issues if needed**

The `list_preauths_for_user/1` likely returns preauth structs. We need `preauth.bot_user.user.username` for the bot name. If not preloaded, add `Repo.preload(preauths, [bot_user: :user])` in `load_preauths/1`, or adjust the template to use the `owner_info` data differently.

- [ ] **Step 7: Run full suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: preauthorizations page with list and revoke"
```

---

### Task 6: Admin Panel (`/admin`)

**Files:**
- Modify: `lib/stackcoin_web/live/admin_live.ex` (replace placeholder)
- Create: `test/stackcoin_web/live/admin_live_test.exs`

- [ ] **Step 1: Write the tests**

Create `test/stackcoin_web/live/admin_live_test.exs`:

```elixir
defmodule StackCoinWebTest.AdminLiveTest do
  use StackCoinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias StackCoin.Core.{User, Bank, Reserve}

  setup do
    {:ok, reserve} = User.create_user_account("1", "Reserve", balance: 10_000)
    {:ok, admin} = User.create_user_account("admin_discord", "admin", balance: 0)
    StackCoin.Repo.update!(Ecto.Changeset.change(admin, admin: true))
    # Reload to get updated admin field
    {:ok, admin} = User.get_user_by_id(admin.id)

    {:ok, alice} = User.create_user_account("alice_discord", "alice", balance: 0)
    {:ok, _} = Bank.transfer_between_users(reserve.id, alice.id, 500, "Seed alice")

    %{admin: admin, alice: alice, reserve: reserve}
  end

  defp login(conn, user) do
    conn |> Plug.Test.init_test_session(%{user_id: user.id})
  end

  describe "auth guard" do
    test "redirects when not logged in", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => _}}}} =
               live(conn, ~p"/admin")
    end

    test "redirects non-admin users", %{conn: conn, alice: alice} do
      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => _}}}} =
               conn |> login(alice) |> live(~p"/admin")
    end
  end

  describe "admin access" do
    test "renders admin page", %{conn: conn, admin: admin} do
      {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin")

      assert html =~ "Admin"
      assert html =~ "Reserve"
      assert html =~ "User Management"
    end

    test "shows reserve balance", %{conn: conn, admin: admin} do
      {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin")

      assert html =~ "STK"
    end

    test "pump reserve works", %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      html =
        view
        |> form("form[phx-submit=pump]", %{amount: "1000", label: "Test pump"})
        |> render_submit()

      assert html =~ "Reserve pumped"
    end

    test "select user shows ban status", %{conn: conn, admin: admin, alice: alice} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      html =
        view
        |> form("form[phx-change=select_user]", %{user_id: to_string(alice.id)})
        |> render_change()

      assert html =~ "alice"
      assert html =~ "Ban"
    end

    test "ban user works", %{conn: conn, admin: admin, alice: alice} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      view
      |> form("form[phx-change=select_user]", %{user_id: to_string(alice.id)})
      |> render_change()

      html = render_click(view, "ban_user")

      assert html =~ "banned"
    end

    test "dole ban user works", %{conn: conn, admin: admin, alice: alice} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      view
      |> form("form[phx-change=select_user]", %{user_id: to_string(alice.id)})
      |> render_change()

      html = render_click(view, "dole_ban_user")

      assert html =~ "dole banned" || html =~ "DOLE BANNED"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/stackcoin_web/live/admin_live_test.exs`
Expected: failures.

- [ ] **Step 3: Implement AdminLive**

Replace `lib/stackcoin_web/live/admin_live.ex`:

```elixir
defmodule StackCoinWeb.AdminLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.{User, Reserve}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
    end

    {:ok, assign(socket, selected_user: nil, all_users: [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    current_user = socket.assigns[:current_user]

    cond do
      current_user == nil ->
        {:noreply,
         socket
         |> put_flash(:error, "You must be logged in.")
         |> push_navigate(to: ~p"/")}

      !socket.assigns[:is_admin] ->
        {:noreply,
         socket
         |> put_flash(:error, "Admin access required.")
         |> push_navigate(to: ~p"/")}

      true ->
        {:ok, reserve_balance} = Reserve.get_reserve_balance()
        {:ok, all_users} = User.list_users_by_last_activity()

        {:noreply,
         socket
         |> assign(:reserve_balance, reserve_balance)
         |> assign(:all_users, all_users)
         |> assign(:page_title, "Admin — StackCoin")}
    end
  end

  @impl true
  def handle_event("pump", %{"amount" => amount_str, "label" => label}, socket) do
    current_user = socket.assigns.current_user
    discord_snowflake = get_discord_snowflake(current_user)

    case Integer.parse(amount_str) do
      {amount, _} when amount > 0 ->
        case Reserve.admin_pump_reserve(discord_snowflake, amount, label) do
          {:ok, _pump} ->
            {:ok, new_balance} = Reserve.get_reserve_balance()

            {:noreply,
             socket
             |> assign(:reserve_balance, new_balance)
             |> put_flash(:info, "Reserve pumped. New balance: #{new_balance} STK")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, format_error(reason))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Enter a valid amount.")}
    end
  end

  def handle_event("select_user", %{"user_id" => ""}, socket) do
    {:noreply, assign(socket, :selected_user, nil)}
  end

  def handle_event("select_user", %{"user_id" => user_id_str}, socket) do
    case User.get_user_by_id(String.to_integer(user_id_str)) do
      {:ok, user} -> {:noreply, assign(socket, :selected_user, user)}
      _ -> {:noreply, assign(socket, :selected_user, nil)}
    end
  end

  def handle_event("ban_user", _params, socket) do
    user = socket.assigns.selected_user
    discord_snowflake = get_discord_snowflake(socket.assigns.current_user)

    result =
      if user.banned,
        do: User.admin_unban_user(discord_snowflake, get_discord_snowflake_for(user)),
        else: User.admin_ban_user(discord_snowflake, get_discord_snowflake_for(user))

    case result do
      {:ok, _} ->
        action = if user.banned, do: "unbanned", else: "banned"
        {:ok, updated} = User.get_user_by_id(user.id)

        {:noreply,
         socket
         |> assign(:selected_user, updated)
         |> put_flash(:info, "#{user.username} #{action}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("dole_ban_user", _params, socket) do
    user = socket.assigns.selected_user
    discord_snowflake = get_discord_snowflake(socket.assigns.current_user)

    result =
      if user.dole_banned,
        do: User.admin_dole_unban_user(discord_snowflake, get_discord_snowflake_for(user)),
        else: User.admin_dole_ban_user(discord_snowflake, get_discord_snowflake_for(user))

    case result do
      {:ok, _} ->
        action = if user.dole_banned, do: "dole unbanned", else: "dole banned"
        {:ok, updated} = User.get_user_by_id(user.id)

        {:noreply,
         socket
         |> assign(:selected_user, updated)
         |> put_flash(:info, "#{user.username} #{action}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  @impl true
  def handle_info({:new_transaction, _}, socket) do
    {:ok, reserve_balance} = Reserve.get_reserve_balance()
    {:noreply, assign(socket, :reserve_balance, reserve_balance)}
  end

  defp get_discord_snowflake(user) do
    case StackCoin.Repo.preload(user, :discord_user) do
      %{discord_user: %{snowflake: snowflake}} when not is_nil(snowflake) ->
        to_string(snowflake)

      _ ->
        nil
    end
  end

  defp get_discord_snowflake_for(user) do
    get_discord_snowflake(user)
  end

  defp format_error(:not_admin), do: "Admin permission required."
  defp format_error(:user_not_found), do: "User not found."
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>

      <h1 class="text-2xl font-bold mb-4">Admin</h1>

      <div class="mb-8">
        <h2 class="text-lg font-bold mb-3">Reserve</h2>
        <p class="text-lg font-mono mb-4">{@reserve_balance} STK</p>

        <form phx-submit="pump" class="flex items-center gap-2">
          <input
            type="number"
            name="amount"
            min="1"
            placeholder="Amount"
            required
            class="border border-gray-200 px-3 py-2 text-sm w-32 font-mono"
          />
          <input
            type="text"
            name="label"
            placeholder="Label"
            required
            class="border border-gray-200 px-3 py-2 text-sm"
          />
          <button type="submit" class="border border-black px-4 py-2 text-sm font-bold">
            Pump
          </button>
        </form>
      </div>

      <div class="mb-8">
        <h2 class="text-lg font-bold mb-3">User Management</h2>

        <form phx-change="select_user" class="mb-4">
          <select name="user_id" class="w-full border border-gray-200 px-3 py-2 text-sm bg-white">
            <option value="">Select a user</option>
            <option
              :for={user <- @all_users}
              value={user.id}
              selected={@selected_user && user.id == @selected_user.id}
            >
              {user.username}
            </option>
          </select>
        </form>

        <%= if @selected_user do %>
          <div class="border border-gray-200 px-4 py-3">
            <div class="flex items-center gap-2 mb-3">
              <span class="font-bold">{@selected_user.username}</span>
              <span
                :if={@selected_user.banned}
                class="text-xs uppercase tracking-wide px-1 border text-red-700 border-red-300"
              >
                BANNED
              </span>
              <span
                :if={@selected_user.dole_banned}
                class="text-xs uppercase tracking-wide px-1 border text-orange-700 border-orange-300"
              >
                DOLE BANNED
              </span>
            </div>
            <div class="flex items-center gap-2">
              <button
                phx-click="ban_user"
                class={[
                  "border px-3 py-1 text-xs",
                  @selected_user.banned && "border-black font-bold",
                  !@selected_user.banned && "border-gray-300 text-gray-500"
                ]}
              >
                <%= if @selected_user.banned, do: "Unban", else: "Ban" %>
              </button>
              <button
                phx-click="dole_ban_user"
                class={[
                  "border px-3 py-1 text-xs",
                  @selected_user.dole_banned && "border-black font-bold",
                  !@selected_user.dole_banned && "border-gray-300 text-gray-500"
                ]}
              >
                <%= if @selected_user.dole_banned, do: "Dole Unban", else: "Dole Ban" %>
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/stackcoin_web/live/admin_live_test.exs --trace`
Expected: pass. Watch for issues with `admin_pump_reserve` — it takes a discord snowflake string, not a user ID. The `get_discord_snowflake/1` helper handles this.

- [ ] **Step 5: Fix any issues with admin ban functions**

The `admin_ban_user/2` and related functions take `(admin_discord_snowflake, target_discord_snowflake)`. Both are discord snowflake strings. Make sure `get_discord_snowflake_for/1` returns the right format for the target user too.

- [ ] **Step 6: Run full suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: admin panel with pump reserve, ban/unban, dole-ban/unban"
```

---

### Task 7: Balance Graph Time Range

**Files:**
- Modify: `lib/stackcoin_web/controllers/graph_controller.ex`
- Modify: `lib/stackcoin/graph_cache.ex`
- Modify: `lib/stackcoin_web/live/user_live.ex`
- Modify: `test/stackcoin_web/live/user_live_test.exs`

- [ ] **Step 1: Add time range test to user_live_test**

Add to `test/stackcoin_web/live/user_live_test.exs`, in a new describe block:

```elixir
  describe "balance graph time range" do
    test "renders time range tabs", %{conn: conn, alice: alice} do
      {:ok, _view, html} = live(conn, ~p"/user/#{alice.id}")

      assert html =~ "All"
      assert html =~ "1w"
      assert html =~ "1m"
      assert html =~ "3m"
      assert html =~ "1y"
    end

    test "time range tab updates graph src", %{conn: conn, alice: alice} do
      {:ok, view, _html} = live(conn, ~p"/user/#{alice.id}")

      html = view |> element("a", "1w") |> render_click()
      assert html =~ "range=1w"
    end

    test "all tab clears range", %{conn: conn, alice: alice} do
      {:ok, view, _html} = live(conn, ~p"/user/#{alice.id}?range=1w")

      html = view |> element("a", "All") |> render_click()
      refute html =~ "range="
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/stackcoin_web/live/user_live_test.exs --trace`
Expected: new tests fail (no time range tabs rendered yet).

- [ ] **Step 3: Update GraphController to accept range param**

Replace `lib/stackcoin_web/controllers/graph_controller.ex`:

```elixir
defmodule StackCoinWeb.GraphController do
  use StackCoinWeb, :controller

  alias StackCoin.GraphCache

  @valid_ranges %{
    "1w" => 7,
    "1m" => 30,
    "3m" => 90,
    "1y" => 365
  }

  def show(conn, params) do
    user_id = String.to_integer(params["user_id"])
    range = params["range"]
    timerange_key = if range in Map.keys(@valid_ranges), do: range, else: "all"

    since =
      case Map.get(@valid_ranges, range) do
        nil -> nil
        days -> NaiveDateTime.add(NaiveDateTime.utc_now(), -days * 86400, :second)
      end

    case GraphCache.get_graph_png(user_id, timerange_key, since) do
      {:ok, png} ->
        conn
        |> put_resp_content_type("image/png")
        |> put_resp_header("cache-control", "public, immutable, max-age=31536000")
        |> send_resp(200, png)

      {:error, :no_transactions} ->
        conn |> send_resp(404, "No transactions")

      {:error, _} ->
        conn |> send_resp(500, "Error generating graph")
    end
  end
end
```

- [ ] **Step 4: Update GraphCache to accept and forward `since`**

Replace `lib/stackcoin/graph_cache.ex`:

```elixir
defmodule StackCoin.GraphCache do
  @moduledoc """
  Disk-based cache for user balance graphs.
  Cached PNGs are stored in /tmp/stackcoin/graphs/ and keyed by
  {user_id, last_transaction_id, timerange} so they stay valid until
  a new transaction involving that user occurs.
  """

  alias StackCoin.Core.{Bank, User}
  alias StackCoin.Graph

  @cache_dir "/tmp/stackcoin/graphs"

  @doc """
  Returns the cached PNG binary for a user's balance graph,
  generating it if the cache is stale or missing.
  """
  def get_graph_png(user_id, timerange_key \\ "all", since \\ nil) do
    with {:ok, last_tx_id} <- get_last_transaction_id(user_id),
         cache_path = cache_path(user_id, last_tx_id, timerange_key),
         {:ok, png} <- read_cached(cache_path) do
      {:ok, png}
    else
      {:miss, cache_path} ->
        generate_and_cache(user_id, cache_path, since)

      {:error, :no_transactions} ->
        {:error, :no_transactions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_last_transaction_id(user_id) do
    case Bank.search_transactions(includes_user_id: user_id, limit: 1) do
      {:ok, %{transactions: [tx | _]}} -> {:ok, tx.id}
      {:ok, %{transactions: []}} -> {:error, :no_transactions}
      error -> error
    end
  end

  defp cache_path(user_id, tx_id, timerange_key) do
    safe_key = String.replace(timerange_key, ~r/[^a-zA-Z0-9]/, "_")
    Path.join(@cache_dir, "#{user_id}_#{tx_id}_#{safe_key}.png")
  end

  defp read_cached(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:miss, path}
    end
  end

  defp generate_and_cache(user_id, cache_path, since) do
    opts = if since, do: [since: since], else: []
    chart_opts = if since, do: [zoomed: true], else: []

    with {:ok, user} <- User.get_user_by_id(user_id),
         {:ok, history} <- Bank.get_user_balance_history(user_id, opts),
         png <- Graph.generate_balance_chart(history, user.username, chart_opts) do
      File.mkdir_p!(Path.dirname(cache_path))
      cleanup_old_files(user_id)
      File.write!(cache_path, png)
      {:ok, png}
    end
  end

  defp cleanup_old_files(user_id) do
    glob = Path.join(@cache_dir, "#{user_id}_*.png")

    for path <- Path.wildcard(glob) do
      File.rm(path)
    end
  end
end
```

- [ ] **Step 5: Add time range tabs to UserLive**

In `lib/stackcoin_web/live/user_live.ex`, make these changes:

1. In `handle_params`, parse the `range` param and assign it:

After `page = parse_page(params["page"])`, add:
```elixir
    range = parse_range(params["range"])
```

Add the `range` assign in the success branch:
```elixir
         |> assign(:range, range)
```

Add the parse helper:
```elixir
  @valid_ranges ~w(1w 1m 3m 1y)

  defp parse_range(nil), do: nil
  defp parse_range(r) when r in @valid_ranges, do: r
  defp parse_range(_), do: nil
```

2. Update `patch_url` to preserve the range:
```elixir
  defp patch_url(assigns) do
    fn page ->
      case assigns.range do
        nil -> ~p"/user/#{assigns.user.id}?page=#{page}"
        range -> ~p"/user/#{assigns.user.id}?page=#{page}&range=#{range}"
      end
    end
  end
```

3. In the template, add time range tabs above the balance graph. Replace the graph section (the `<div :if={@has_transactions} class="max-w-5xl ...">` block) with:

```heex
    <div :if={@has_transactions} class="max-w-5xl mx-auto px-4 mb-6 w-full">
      <h2 class="text-lg font-bold mb-3">Balance History</h2>
      <nav class="flex gap-6 mb-4 border-b border-gray-200">
        <.link
          patch={~p"/user/#{@user.id}"}
          class={["pb-2 text-sm", @range == nil && "border-b-2 border-black font-bold"]}
        >
          All
        </.link>
        <.link
          :for={r <- ~w(1w 1m 3m 1y)}
          patch={~p"/user/#{@user.id}?range=#{r}"}
          class={["pb-2 text-sm", @range == r && "border-b-2 border-black font-bold"]}
        >
          {r}
        </.link>
      </nav>
      <div class="border border-gray-200">
        <img
          src={graph_src(@user.id, @graph_cache_buster, @range)}
          alt={"#{@user.username}'s balance over time"}
          class="w-full"
        />
      </div>
    </div>
```

Add the helper:
```elixir
  defp graph_src(user_id, cache_buster, nil), do: ~p"/graph/#{user_id}?v=#{cache_buster}"
  defp graph_src(user_id, cache_buster, range), do: ~p"/graph/#{user_id}?v=#{cache_buster}&range=#{range}"
```

- [ ] **Step 6: Run tests**

Run: `mix test test/stackcoin_web/live/user_live_test.exs --trace`
Expected: all tests pass (existing + new time range tests).

- [ ] **Step 7: Run full suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: balance graph time range filter with 1w/1m/3m/1y tabs"
```

---

### Task 8: Transaction Direction Filter

**Files:**
- Modify: `lib/stackcoin_web/live/transactions_live.ex`
- Modify: `test/stackcoin_web/live/transactions_live_test.exs`

- [ ] **Step 1: Add direction filter tests**

Add to `test/stackcoin_web/live/transactions_live_test.exs`, in the `"public access"` describe:

```elixir
    test "direction filter shows when user is selected", %{conn: conn, alice: alice} do
      {:ok, view, _html} = live(conn, ~p"/transactions?user=#{alice.id}")

      html = render(view)
      assert html =~ "Direction"
    end

    test "direction filter hidden when no user selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/transactions")

      refute html =~ "Direction"
    end

    test "from filter works", %{conn: conn, alice: alice, bob: bob} do
      {:ok, _view, html} = live(conn, ~p"/transactions?user=#{alice.id}&dir=from")

      # Alice sent 100 to bob, so "from alice" should show that transaction
      assert html =~ "alice"
    end

    test "to filter works", %{conn: conn, alice: alice} do
      {:ok, _view, html} = live(conn, ~p"/transactions?user=#{alice.id}&dir=to")

      # Alice received 500 from reserve
      assert html =~ "alice"
    end

    test "direction filter changes via form", %{conn: conn, alice: alice} do
      {:ok, view, _html} = live(conn, ~p"/transactions?user=#{alice.id}")

      html =
        view
        |> form("form", %{dir: "from"})
        |> render_change()

      assert html =~ "alice"
    end
```

- [ ] **Step 2: Run tests to verify new ones fail**

Run: `mix test test/stackcoin_web/live/transactions_live_test.exs --trace`
Expected: new tests fail.

- [ ] **Step 3: Update TransactionsLive**

In `lib/stackcoin_web/live/transactions_live.ex`, make these changes:

1. In `handle_params`, parse the `dir` param:

```elixir
    dir = parse_dir(params["dir"])
```

Add to assigns:
```elixir
     |> assign(:filter_dir, dir)
```

Add helper:
```elixir
  defp parse_dir("from"), do: "from"
  defp parse_dir("to"), do: "to"
  defp parse_dir(_), do: nil
```

2. Replace `maybe_add_user_filter/2` with direction-aware version:

```elixir
  defp maybe_add_user_filter(opts, nil, _dir), do: opts

  defp maybe_add_user_filter(opts, user_id, "from"),
    do: Keyword.put(opts, :from_user_id, user_id)

  defp maybe_add_user_filter(opts, user_id, "to"),
    do: Keyword.put(opts, :to_user_id, user_id)

  defp maybe_add_user_filter(opts, user_id, _),
    do: Keyword.put(opts, :includes_user_id, user_id)
```

3. Update all calls to `maybe_add_user_filter` to pass the dir:

In `handle_params`:
```elixir
    opts =
      [limit: @per_page, offset: offset]
      |> maybe_add_user_filter(user_id, dir)
```

In `handle_info`:
```elixir
      opts =
        [limit: @per_page, offset: 0]
        |> maybe_add_user_filter(socket.assigns.filter_user_id, socket.assigns.filter_dir)
```

4. Update `handle_event("filter_user", ...)` to preserve direction:

```elixir
  def handle_event("filter_user", %{"user_id" => ""}, socket) do
    {:noreply, push_patch(socket, to: ~p"/transactions")}
  end

  def handle_event("filter_user", %{"user_id" => user_id} = params, socket) do
    dir = params["dir"]

    path =
      case dir do
        d when d in ["from", "to"] -> ~p"/transactions?user=#{user_id}&dir=#{d}"
        _ -> ~p"/transactions?user=#{user_id}"
      end

    {:noreply, push_patch(socket, to: path)}
  end
```

Add a new event for direction changes:
```elixir
  def handle_event("filter_dir", %{"dir" => dir}, socket) do
    user_id = socket.assigns.filter_user_id

    path =
      case dir do
        d when d in ["from", "to"] -> ~p"/transactions?user=#{user_id}&dir=#{d}"
        _ -> ~p"/transactions?user=#{user_id}"
      end

    {:noreply, push_patch(socket, to: path)}
  end
```

5. Update `patch_url` to preserve both user and direction:

```elixir
  defp patch_url(assigns) do
    fn page ->
      case {assigns.filter_user_id, assigns.filter_dir} do
        {nil, _} -> ~p"/transactions?page=#{page}"
        {uid, nil} -> ~p"/transactions?user=#{uid}&page=#{page}"
        {uid, dir} -> ~p"/transactions?user=#{uid}&dir=#{dir}&page=#{page}"
      end
    end
  end
```

6. Update the template filter section. Replace the existing `<form phx-change="filter_user" ...>` block with:

```heex
      <form phx-change="filter_user" class="mb-6">
        <div class="flex gap-4">
          <div class="flex-1">
            <label class="block text-sm text-gray-500 mb-1">User</label>
            <select
              name="user_id"
              class="w-full border border-gray-200 px-3 py-2 text-sm bg-white"
            >
              <option value="">All users</option>
              <option
                :for={user <- @all_users}
                value={user.id}
                selected={user.id == @filter_user_id}
              >
                {user.username}
              </option>
            </select>
          </div>
          <div :if={@filter_user_id} class="w-40">
            <label class="block text-sm text-gray-500 mb-1">Direction</label>
            <select
              name="dir"
              class="w-full border border-gray-200 px-3 py-2 text-sm bg-white"
            >
              <option value="" selected={@filter_dir == nil}>Involving</option>
              <option value="from" selected={@filter_dir == "from"}>From</option>
              <option value="to" selected={@filter_dir == "to"}>To</option>
            </select>
          </div>
        </div>
      </form>
```

- [ ] **Step 4: Run tests**

Run: `mix test test/stackcoin_web/live/transactions_live_test.exs --trace`
Expected: all tests pass.

- [ ] **Step 5: Run full suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: transaction direction filter (from/to/involving)"
```

---

### Task 9: Final integration verification

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: all tests pass (should be 400+ now with new LiveView tests).

- [ ] **Step 2: Start the dev server and manually verify**

Run: `mix phx.server`

Check:
1. Nav bar shows Bots/Preauths links when logged in, Admin link for admin
2. `/bots` — create, list, token reveal, reset, delete all work
3. `/preauths` — lists preauths, revoke works
4. `/admin` — pump, ban/unban, dole-ban/unban all work
5. `/user/:id` — time range tabs filter the graph
6. `/transactions` — direction filter appears when user selected

- [ ] **Step 3: Commit any final fixes**

```bash
git add -A && git commit -m "fix: integration fixes from manual testing"
```

(Only if there are fixes to make.)
