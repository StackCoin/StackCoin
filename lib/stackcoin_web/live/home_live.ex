defmodule StackCoinWeb.HomeLive do
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
  def handle_params(params, _uri, socket) do
    filter = parse_filter(params["filter"])

    {:ok, users} = User.list_users_by_last_activity(filter)
    {:ok, %{transactions: recent_transactions}} = Bank.search_transactions(limit: 5)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:users, users)
     |> assign(:recent_transactions, recent_transactions)
     |> assign(:page_title, "StackCoin")}
  end

  @impl true
  def handle_info({:new_transaction, _transaction}, socket) do
    {:ok, users} = User.list_users_by_last_activity(socket.assigns.filter)
    {:ok, %{transactions: recent_transactions}} = Bank.search_transactions(limit: 5)

    {:noreply,
     socket
     |> assign(:users, users)
     |> assign(:recent_transactions, recent_transactions)}
  end

  defp parse_filter("bots"), do: :bots
  defp parse_filter("users"), do: :users
  defp parse_filter(_), do: :all

  defp format_time(nil), do: {"never", nil}

  defp format_time(naive_datetime) do
    now = NaiveDateTime.utc_now()
    diff = NaiveDateTime.diff(now, naive_datetime, :second)

    short =
      cond do
        diff < 60 -> "#{diff}s ago"
        diff < 3600 -> "#{div(diff, 60)}m ago"
        diff < 86400 -> "#{div(diff, 3600)}h ago"
        diff < 365 * 86400 -> "#{div(diff, 86400)}d ago"
        true -> format_month_year(naive_datetime)
      end

    full = Calendar.strftime(naive_datetime, "%B %-d, %Y at %-I:%M %p UTC")
    {short, full}
  end

  defp format_month_year(naive_datetime) do
    month = Calendar.strftime(naive_datetime, "%b")
    year = naive_datetime.year |> Integer.to_string() |> String.slice(-2..-1//1)
    "#{month} '#{year}"
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

      <div :if={@recent_transactions != []} class="mb-8">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-lg font-bold">Recent Transactions</h2>
          <.link navigate={~p"/transactions"} class="text-sm text-gray-500">
            View all &rarr;
          </.link>
        </div>

        <div class="border border-gray-200">
          <div
            :for={tx <- @recent_transactions}
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
            <% {short, full} = format_time(tx.time) %>
            <time
              :if={full}
              datetime={NaiveDateTime.to_iso8601(tx.time)}
              title={full}
              class="text-sm text-gray-500"
            >
              {short}
            </time>
            <span :if={!full} class="text-sm text-gray-500">{short}</span>
          </div>
        </div>
      </div>

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
            <% {short, full} = format_time(user.last_active) %>
            <time
              :if={full}
              datetime={NaiveDateTime.to_iso8601(user.last_active)}
              title={full}
              class="text-sm text-gray-500 w-16 text-right"
            >
              {short}
            </time>
            <span :if={!full} class="text-sm text-gray-500 w-16 text-right">{short}</span>
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
