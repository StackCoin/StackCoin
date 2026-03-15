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
