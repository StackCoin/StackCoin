defmodule StackCoinWeb.BotsLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.{Bot, Bank}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
    end

    {:ok, assign(socket, delete_bot: nil, delete_confirmation: "")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if socket.assigns[:current_user] == nil do
      {:noreply,
       socket
       |> put_flash(:error, "You must be logged in to manage bots.")
       |> push_navigate(to: ~p"/")}
    else
      snowflake = get_discord_snowflake(socket.assigns.current_user)

      bots = load_bots(snowflake)

      {:noreply,
       socket
       |> assign(:page_title, "Bots — StackCoin")
       |> assign(:snowflake, snowflake)
       |> assign(:bots, bots)
       |> assign(:revealed_tokens, %{})
       |> assign(:show_tokens, MapSet.new())}
    end
  end

  @impl true
  def handle_event("create_bot", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, "Bot name cannot be empty.")}
    else
      snowflake = socket.assigns.snowflake
      user = socket.assigns.current_user

      if user.admin do
        case Bot.admin_create_bot_user(snowflake, name) do
          {:ok, bot} ->
            # Try to DM the token via Discord (best effort)
            try do
              discord_id = String.to_integer(snowflake)
              StackCoin.Bot.Discord.Bot.send_bot_token_dm(discord_id, bot)
            rescue
              _ -> :ok
            end

            bots = load_bots(snowflake)

            {:noreply,
             socket
             |> assign(:bots, bots)
             |> assign(
               :revealed_tokens,
               Map.put(socket.assigns.revealed_tokens, bot.id, bot.token)
             )
             |> assign(:show_tokens, MapSet.put(socket.assigns.show_tokens, bot.id))
             |> put_flash(:info, "Bot \"#{name}\" created.")}

          {:error, :not_admin} ->
            {:noreply, put_flash(socket, :error, "Only admins can create bots directly.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, format_error(reason))}
        end
      else
        # Non-admin: send creation request DM to admin
        try do
          discord_id = String.to_integer(snowflake)
          StackCoin.Bot.Discord.Bot.send_bot_creation_request_dm(discord_id, name)
        rescue
          _ -> :ok
        end

        {:noreply,
         put_flash(
           socket,
           :info,
           "Bot creation request sent. An admin will review it via Discord."
         )}
      end
    end
  end

  def handle_event("show_delete_modal", %{"bot-id" => bot_id_str}, socket) do
    bot_id = String.to_integer(bot_id_str)
    bot = Enum.find(socket.assigns.bots, &(&1.id == bot_id))

    {:noreply,
     socket
     |> assign(:delete_bot, bot)
     |> assign(:delete_confirmation, "")}
  end

  def handle_event("update_delete_confirmation", %{"confirmation" => value}, socket) do
    {:noreply, assign(socket, :delete_confirmation, value)}
  end

  def handle_event("confirm_delete_bot", _params, socket) do
    bot = socket.assigns.delete_bot

    if bot && socket.assigns.delete_confirmation == bot.name do
      snowflake = socket.assigns.snowflake

      case Bot.delete_bot_user(snowflake, bot.id) do
        {:ok, deleted_bot} ->
          bots = load_bots(snowflake)

          {:noreply,
           socket
           |> assign(:bots, bots)
           |> assign(:delete_bot, nil)
           |> assign(:delete_confirmation, "")
           |> assign(
             :revealed_tokens,
             Map.delete(socket.assigns.revealed_tokens, deleted_bot.id)
           )
           |> assign(:show_tokens, MapSet.delete(socket.assigns.show_tokens, deleted_bot.id))
           |> put_flash(:info, "Bot deleted.")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:delete_bot, nil)
           |> assign(:delete_confirmation, "")
           |> put_flash(:error, format_error(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply,
     socket
     |> assign(:delete_bot, nil)
     |> assign(:delete_confirmation, "")}
  end

  def handle_event("reset_token", %{"bot-id" => bot_id_str}, socket) do
    bot_id = String.to_integer(bot_id_str)
    snowflake = socket.assigns.snowflake

    case Bot.reset_bot_token(snowflake, bot_id) do
      {:ok, updated_bot} ->
        # Try to DM the new token via Discord (best effort)
        try do
          discord_id = String.to_integer(snowflake)
          StackCoin.Bot.Discord.Bot.send_bot_token_dm(discord_id, updated_bot)
        rescue
          _ -> :ok
        end

        {:noreply,
         socket
         |> assign(
           :revealed_tokens,
           Map.put(socket.assigns.revealed_tokens, updated_bot.id, updated_bot.token)
         )
         |> assign(:show_tokens, MapSet.put(socket.assigns.show_tokens, updated_bot.id))
         |> put_flash(:info, "Token reset.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("toggle_token", %{"bot-id" => bot_id_str}, socket) do
    bot_id = String.to_integer(bot_id_str)

    show_tokens =
      if MapSet.member?(socket.assigns.show_tokens, bot_id) do
        MapSet.delete(socket.assigns.show_tokens, bot_id)
      else
        MapSet.put(socket.assigns.show_tokens, bot_id)
      end

    {:noreply, assign(socket, :show_tokens, show_tokens)}
  end

  @impl true
  def handle_info({:new_transaction, _transaction}, socket) do
    snowflake = socket.assigns.snowflake
    bots = load_bots(snowflake)
    {:noreply, assign(socket, :bots, bots)}
  end

  defp load_bots(nil), do: []

  defp load_bots(snowflake) do
    case Bot.get_user_bots(snowflake) do
      {:ok, bots} ->
        Enum.map(bots, fn bot ->
          balance =
            case Bank.get_user_balance(bot.user_id) do
              {:ok, bal} -> bal
              _ -> 0
            end

          %{
            id: bot.id,
            name: bot.name,
            user_id: bot.user_id,
            token: bot.token,
            balance: balance
          }
        end)

      _ ->
        []
    end
  end

  defp get_discord_snowflake(user) do
    case StackCoin.Repo.preload(user, :discord_user) do
      %{discord_user: %{snowflake: snowflake}} when not is_nil(snowflake) ->
        to_string(snowflake)

      _ ->
        nil
    end
  end

  defp format_error(:bot_not_found), do: "Bot not found."
  defp format_error(:not_admin), do: "Only admins can do this."
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Operation failed: #{inspect(reason)}"

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

        <div :if={@bots == []} class="border border-gray-200">
          <div class="px-4 py-8 text-center text-gray-500">
            You don't have any bots yet.
          </div>
        </div>

        <div :if={@bots != []} class="border border-gray-200">
          <div
            :for={bot <- @bots}
            class="px-4 py-3 border-b border-gray-200 last:border-b-0"
          >
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <.link navigate={~p"/user/#{bot.user_id}"} class="font-medium text-gray-900">
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
                  phx-value-bot-id={bot.id}
                  class="border border-black px-3 py-1 text-xs font-bold"
                >
                  Reset Token
                </button>
                <button
                  phx-click="show_delete_modal"
                  phx-value-bot-id={bot.id}
                  class="border border-gray-300 px-3 py-1 text-xs text-gray-500"
                >
                  Delete
                </button>
              </div>
            </div>

            <div
              :if={Map.has_key?(@revealed_tokens, bot.id)}
              class="mt-2 flex items-center gap-2"
            >
              <code class="text-xs bg-gray-100 px-2 py-1 font-mono">
                <%= if MapSet.member?(@show_tokens, bot.id) do %>
                  {Map.get(@revealed_tokens, bot.id)}
                <% else %>
                  ••••••••
                <% end %>
              </code>
              <button
                phx-click="toggle_token"
                phx-value-bot-id={bot.id}
                class="border border-gray-300 px-3 py-1 text-xs text-gray-500"
              >
                <%= if MapSet.member?(@show_tokens, bot.id), do: "Hide", else: "Show" %>
              </button>
              <button
                id={"copy-token-#{bot.id}"}
                phx-hook="Clipboard"
                data-clipboard-text={Map.get(@revealed_tokens, bot.id)}
                class="border border-gray-300 px-3 py-1 text-xs text-gray-500"
              >
                Copy
              </button>
            </div>
          </div>
        </div>
      </div>

      <div :if={@delete_bot} class="fixed inset-0 z-50 flex items-center justify-center">
        <div class="fixed inset-0 bg-white/80" phx-click="cancel_delete" />
        <div class="relative border border-gray-200 bg-white px-6 py-5 max-w-sm w-full mx-4">
          <h2 class="text-lg font-bold mb-2">Delete Bot</h2>
          <p class="text-sm text-gray-500 mb-4">
            Type <span class="font-bold text-gray-900">{@delete_bot.name}</span>
            to confirm deletion. This cannot be undone.
          </p>
          <form phx-submit="confirm_delete_bot" phx-change="update_delete_confirmation">
            <input
              type="text"
              name="confirmation"
              value={@delete_confirmation}
              placeholder="Bot name"
              autocomplete="off"
              class="border border-gray-200 px-3 py-2 text-sm w-full mb-4"
            />
            <div class="flex items-center gap-2">
              <button
                type="submit"
                disabled={@delete_confirmation != @delete_bot.name}
                class={[
                  "border px-4 py-2 text-sm font-bold",
                  @delete_confirmation == @delete_bot.name &&
                    "border-red-700 text-red-700",
                  @delete_confirmation != @delete_bot.name &&
                    "border-gray-200 text-gray-300 cursor-not-allowed"
                ]}
              >
                Delete Bot
              </button>
              <button
                type="button"
                phx-click="cancel_delete"
                class="border border-gray-300 px-4 py-2 text-sm text-gray-500"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
