defmodule StackCoinWeb.TransactionsLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.{Bank, User}

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
    end

    {:ok, all_users} = User.list_users_by_last_activity()

    {:ok, assign(socket, :all_users, all_users)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
    user_id = parse_user_id(params["user"])
    offset = (page - 1) * @per_page

    opts =
      [limit: @per_page, offset: offset]
      |> maybe_add_user_filter(user_id)

    {:ok, %{transactions: transactions, total_count: total_count}} =
      Bank.search_transactions(opts)

    total_pages = max(ceil(total_count / @per_page), 1)

    {:noreply,
     socket
     |> assign(:transactions, transactions)
     |> assign(:current_page, page)
     |> assign(:total_pages, total_pages)
     |> assign(:total_count, total_count)
     |> assign(:filter_user_id, user_id)
     |> assign(:page_title, "Transactions — StackCoin")}
  end

  @impl true
  def handle_info({:new_transaction, _transaction}, socket) do
    if socket.assigns.current_page == 1 do
      opts =
        [limit: @per_page, offset: 0]
        |> maybe_add_user_filter(socket.assigns.filter_user_id)

      {:ok, %{transactions: transactions, total_count: total_count}} =
        Bank.search_transactions(opts)

      total_pages = max(ceil(total_count / @per_page), 1)

      {:noreply,
       socket
       |> assign(:transactions, transactions)
       |> assign(:total_pages, total_pages)
       |> assign(:total_count, total_count)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_user", %{"user_id" => ""}, socket) do
    {:noreply, push_patch(socket, to: ~p"/transactions")}
  end

  def handle_event("filter_user", %{"user_id" => user_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/transactions?user=#{user_id}")}
  end

  defp parse_page(nil), do: 1

  defp parse_page(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_user_id(nil), do: nil

  defp parse_user_id(str) do
    case Integer.parse(str) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp maybe_add_user_filter(opts, nil), do: opts
  defp maybe_add_user_filter(opts, user_id), do: Keyword.put(opts, :includes_user_id, user_id)

  defp patch_url(assigns) do
    fn page ->
      case assigns.filter_user_id do
        nil -> ~p"/transactions?page=#{page}"
        uid -> ~p"/transactions?user=#{uid}&page=#{page}"
      end
    end
  end

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
    assigns = assign(assigns, :patch_url_fn, patch_url(assigns))

    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>

      <h1 class="text-2xl font-bold mb-4">Transactions</h1>

      <form phx-change="filter_user" class="mb-6">
        <label class="block text-sm text-gray-500 mb-1">Involving</label>
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
      </form>

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

        <div :if={@transactions == []} class="px-4 py-8 text-center text-gray-500">
          No transactions found.
        </div>
      </div>

      <.pagination
        current_page={@current_page}
        total_pages={@total_pages}
        patch_url={@patch_url_fn}
      />
    </div>
    """
  end
end
