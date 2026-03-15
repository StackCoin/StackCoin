defmodule StackCoinWeb.UserLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.{User, Bank}

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    page = parse_page(params["page"])

    case load_user_data(id, page) do
      {:ok, user, transactions, total_count, graph_buster} ->
        total_pages = max(ceil(total_count / @per_page), 1)

        {:noreply,
         socket
         |> assign(:user, user)
         |> assign(:transactions, transactions)
         |> assign(:has_transactions, total_count > 0)
         |> assign(:current_page, page)
         |> assign(:total_pages, total_pages)
         |> assign(:graph_cache_buster, graph_buster)
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
    page = socket.assigns.current_page

    case load_user_data(user_id, page) do
      {:ok, user, transactions, total_count, graph_buster} ->
        total_pages = max(ceil(total_count / @per_page), 1)

        {:noreply,
         socket
         |> assign(:user, user)
         |> assign(:transactions, transactions)
         |> assign(:has_transactions, total_count > 0)
         |> assign(:total_pages, total_pages)
         |> assign(:graph_cache_buster, graph_buster)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp load_user_data(user_id, page) do
    offset = (page - 1) * @per_page

    with {:ok, user} <- User.get_user_detail(user_id),
         {:ok, %{transactions: transactions, total_count: total_count}} <-
           Bank.search_transactions(includes_user_id: user_id, limit: @per_page, offset: offset),
         {:ok, %{transactions: latest}} <-
           Bank.search_transactions(includes_user_id: user_id, limit: 1) do
      graph_buster =
        case latest do
          [tx | _] -> tx.id
          [] -> 0
        end

      {:ok, user, transactions, total_count, graph_buster}
    end
  end

  defp parse_page(nil), do: 1

  defp parse_page(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp patch_url(assigns) do
    fn page -> ~p"/user/#{assigns.user.id}?page=#{page}" end
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
    </div>

    <div :if={@has_transactions} class="max-w-5xl mx-auto px-4 mb-6 w-full">
      <h2 class="text-lg font-bold mb-3">Balance History</h2>
      <div class="border border-gray-200">
        <img
          src={~p"/graph/#{@user.id}?v=#{@graph_cache_buster}"}
          alt={"#{@user.username}'s balance over time"}
          class="w-full"
        />
      </div>
    </div>

    <div class="max-w-2xl mx-auto px-4 pb-6 w-full">
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-lg font-bold">Transactions</h2>
        <.link
          navigate={~p"/transactions?user=#{@user.id}"}
          class="text-sm text-gray-500"
        >
          View all &rarr;
        </.link>
      </div>

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
          No transactions yet.
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
