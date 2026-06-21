defmodule StackCoinWeb.AdminLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.{User, Reserve}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
    end

    {:ok, socket}
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
        {:ok, balance} = Reserve.get_reserve_balance()
        {:ok, users} = User.list_users_by_last_activity()

        {:noreply,
         socket
         |> assign(:page_title, "Admin — StackCoin")
         |> assign(:reserve_balance, balance)
         |> assign(:users, users)
         |> assign(:selected_user, nil)}
    end
  end

  @impl true
  def handle_event("pump", %{"amount" => amount_str, "label" => label}, socket) do
    admin_snowflake = get_discord_snowflake(socket.assigns.current_user)

    case Integer.parse(amount_str) do
      {amount, _} when amount > 0 ->
        case Reserve.admin_pump_reserve(admin_snowflake, amount, label) do
          {:ok, _pump} ->
            {:ok, new_balance} = Reserve.get_reserve_balance()

            {:noreply,
             socket
             |> assign(:reserve_balance, new_balance)
             |> put_flash(:info, "Reserve pumped. New balance: #{new_balance} STK")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Pump failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid amount.")}
    end
  end

  def handle_event("select_user", %{"user_id" => ""}, socket) do
    {:noreply, assign(socket, :selected_user, nil)}
  end

  def handle_event("select_user", %{"user_id" => user_id_str}, socket) do
    case User.get_user_by_id(String.to_integer(user_id_str)) do
      {:ok, user} ->
        {:noreply, assign(socket, :selected_user, user)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "User not found.")}
    end
  end

  def handle_event("ban_user", _params, socket) do
    admin_snowflake = get_discord_snowflake(socket.assigns.current_user)
    target_snowflake = get_discord_snowflake(socket.assigns.selected_user)

    result =
      if socket.assigns.selected_user.banned do
        User.admin_unban_user(admin_snowflake, target_snowflake)
      else
        User.admin_ban_user(admin_snowflake, target_snowflake)
      end

    case result do
      {:ok, updated_user} ->
        action = if updated_user.banned, do: "banned", else: "unbanned"

        {:noreply,
         socket
         |> assign(:selected_user, updated_user)
         |> put_flash(:info, "User #{action}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("dole_ban_user", _params, socket) do
    admin_snowflake = get_discord_snowflake(socket.assigns.current_user)
    target_snowflake = get_discord_snowflake(socket.assigns.selected_user)

    result =
      if socket.assigns.selected_user.dole_banned do
        User.admin_dole_unban_user(admin_snowflake, target_snowflake)
      else
        User.admin_dole_ban_user(admin_snowflake, target_snowflake)
      end

    case result do
      {:ok, updated_user} ->
        action = if updated_user.dole_banned, do: "dole banned", else: "dole unbanned"

        {:noreply,
         socket
         |> assign(:selected_user, updated_user)
         |> put_flash(:info, "User #{action}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:new_transaction, _transaction}, socket) do
    {:ok, balance} = Reserve.get_reserve_balance()
    {:noreply, assign(socket, :reserve_balance, balance)}
  end

  defp get_discord_snowflake(user) do
    case StackCoin.Repo.preload(user, :discord_user) do
      %{discord_user: %{snowflake: snowflake}} when not is_nil(snowflake) ->
        to_string(snowflake)

      _ ->
        nil
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

      <%!-- Reserve Section --%>
      <div class="mb-8">
        <h2 class="text-lg font-bold mb-3">Reserve</h2>
        <p class="text-lg font-mono mb-3"><%= @reserve_balance %> STK</p>
        <form id="pump-reserve-form" phx-submit="pump" class="flex gap-2 items-end">
          <input
            type="number"
            name="amount"
            placeholder="Amount"
            class="border border-gray-200 px-3 py-2 text-sm w-32 font-mono"
            required
          />
          <input
            type="text"
            name="label"
            placeholder="Label"
            class="border border-gray-200 px-3 py-2 text-sm"
            required
          />
          <button type="submit" class="border border-black px-4 py-2 text-sm font-bold">
            Pump
          </button>
        </form>
      </div>

      <%!-- User Management Section --%>
      <div class="mb-8">
        <h2 class="text-lg font-bold mb-3">User Management</h2>
        <form id="select-user-form" phx-change="select_user">
          <select
            name="user_id"
            class="w-full border border-gray-200 px-3 py-2 text-sm bg-white"
          >
            <option value="">Select a user...</option>
            <%= for user <- @users do %>
              <option
                value={to_string(user.id)}
                selected={@selected_user && @selected_user.id == user.id}
              >
                <%= user.username %>
              </option>
            <% end %>
          </select>
        </form>

        <%= if @selected_user do %>
          <div class="border border-gray-200 px-4 py-3 mt-3">
            <div class="flex items-center gap-2 mb-2">
              <span class="font-bold"><%= @selected_user.username %></span>
              <%= if @selected_user.banned do %>
                <span class="text-xs uppercase tracking-wide px-1 border text-red-700 border-red-300">
                  BANNED
                </span>
              <% end %>
              <%= if @selected_user.dole_banned do %>
                <span class="text-xs uppercase tracking-wide px-1 border text-orange-700 border-orange-300">
                  DOLE BANNED
                </span>
              <% end %>
            </div>
            <div class="flex gap-2">
              <button
                phx-click="ban_user"
                class={"border px-3 py-1 text-xs #{if @selected_user.banned, do: "border-black font-bold", else: "border-gray-300 text-gray-500"}"}
              >
                <%= if @selected_user.banned, do: "Unban", else: "Ban" %>
              </button>
              <button
                phx-click="dole_ban_user"
                class={"border px-3 py-1 text-xs #{if @selected_user.dole_banned, do: "border-black font-bold", else: "border-gray-300 text-gray-500"}"}
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
