defmodule StackCoinWeb.PreauthsLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.{Preauthorization, Bot}
  alias StackCoin.Repo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "preauths")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if socket.assigns[:current_user] == nil do
      {:noreply,
       socket
       |> put_flash(:error, "You must be logged in to view preauthorizations.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply,
       socket
       |> assign(:page_title, "Preauthorizations — StackCoin")
       |> load_preauths()}
    end
  end

  @impl true
  def handle_event("revoke", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    case Preauthorization.revoke_preauth(id) do
      {:ok, _preauth} ->
        {:noreply,
         socket
         |> put_flash(:info, "Preauthorization revoked.")
         |> load_preauths()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke preauthorization.")}
    end
  end

  @impl true
  def handle_info({:preauth_approved, _preauth}, socket) do
    {:noreply, load_preauths(socket)}
  end

  def handle_info({:preauth_revoked, _preauth}, socket) do
    {:noreply, load_preauths(socket)}
  end

  defp load_preauths(socket) do
    current_user = socket.assigns.current_user
    {:ok, preauths} = Preauthorization.list_preauths_for_user(current_user.id)

    # Build remaining budgets map
    remaining =
      Map.new(preauths, fn preauth ->
        {:ok, rem} = Preauthorization.get_remaining_budget(preauth.id)
        {preauth.id, rem}
      end)

    # Build owner info map: bot_user_id -> %{owner_id, owner_username}
    owner_info =
      Map.new(preauths, fn preauth ->
        info =
          case Bot.get_bot_owner_info(preauth.bot_user_id) do
            {:ok, {bot_user_record, _display}} ->
              owner = Repo.get(StackCoin.Schema.User, bot_user_record.owner_id)
              %{owner_id: bot_user_record.owner_id, owner_username: owner.username}

            _ ->
              %{owner_id: nil, owner_username: "unknown"}
          end

        {preauth.bot_user_id, info}
      end)

    socket
    |> assign(:preauths, preauths)
    |> assign(:remaining, remaining)
    |> assign(:owner_info, owner_info)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>

      <h1 class="text-2xl font-bold mb-4">Preauthorizations</h1>

      <div :if={@preauths == []} class="border border-gray-200">
        <div class="px-4 py-8 text-center text-gray-500">
          No active preauthorizations.
        </div>
      </div>

      <div :if={@preauths != []} class="border border-gray-200">
        <div
          :for={preauth <- @preauths}
          class="px-4 py-3 border-b border-gray-200 last:border-b-0"
        >
          <div class="flex items-center justify-between">
            <div>
              <div class="flex items-center gap-2">
                <.link navigate={~p"/user/#{preauth.bot_user_id}"} class="font-medium text-gray-900">
                  {preauth.bot_user.username}
                </.link>
                <span class="text-xs uppercase tracking-wide text-gray-500 border border-gray-300 px-1">
                  BOT
                </span>
              </div>
              <div :if={owner = @owner_info[preauth.bot_user_id]} class="text-sm text-gray-500">
                owned by
                <.link navigate={~p"/user/#{owner.owner_id}"} class="underline">
                  {owner.owner_username}
                </.link>
              </div>
              <div class="text-sm text-gray-500">
                Budget: <span class="font-mono">{preauth.max_amount} STK</span> / {preauth.window_hours} hrs
              </div>
              <div class="text-sm text-gray-500">
                Remaining: <span class="font-mono">{@remaining[preauth.id]} STK</span> remaining
              </div>
            </div>
            <button
              phx-click="revoke"
              phx-value-id={preauth.id}
              class="border border-gray-300 px-3 py-1 text-xs text-gray-500"
            >
              Revoke
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
