defmodule StackCoinWeb.HomeLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.{User, Bank, Request}
  alias StackCoin.NetworkCache

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "requests")
    end

    {:ok, network_json} = NetworkCache.get_network_json()

    {:ok, assign(socket, :network_json, network_json)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = parse_filter(params["filter"])

    {:ok, users} = User.list_users_by_last_activity(filter)
    {:ok, %{transactions: recent_transactions}} = Bank.search_transactions(limit: 5)
    pending_requests = load_pending_requests(socket.assigns[:current_user])

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:users, users)
     |> assign(:recent_transactions, recent_transactions)
     |> assign(:pending_requests, pending_requests)
     |> assign(:page_title, "StackCoin")}
  end

  @impl true
  def handle_event("accept_request", %{"id" => request_id}, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      case Request.accept_request(String.to_integer(request_id), current_user.id) do
        {:ok, _} ->
          pending = load_pending_requests(current_user)

          {:noreply,
           socket |> assign(:pending_requests, pending) |> put_flash(:info, "Request accepted.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, format_error(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("deny_request", %{"id" => request_id}, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      case Request.deny_request(String.to_integer(request_id), current_user.id) do
        {:ok, _} ->
          pending = load_pending_requests(current_user)

          {:noreply,
           socket |> assign(:pending_requests, pending) |> put_flash(:info, "Request denied.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, format_error(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({event, _request}, socket)
      when event in [:request_created, :request_accepted, :request_denied] do
    pending_requests = load_pending_requests(socket.assigns[:current_user])
    {:noreply, assign(socket, :pending_requests, pending_requests)}
  end

  @impl true
  def handle_info({:new_transaction, _transaction}, socket) do
    {:ok, users} = User.list_users_by_last_activity(socket.assigns.filter)
    {:ok, %{transactions: recent_transactions}} = Bank.search_transactions(limit: 5)
    {:ok, network_json} = NetworkCache.get_network_json()
    pending_requests = load_pending_requests(socket.assigns[:current_user])

    {:noreply,
     socket
     |> assign(:users, users)
     |> assign(:network_json, network_json)
     |> assign(:recent_transactions, recent_transactions)
     |> assign(:pending_requests, pending_requests)}
  end

  defp load_pending_requests(nil), do: []

  defp load_pending_requests(user) do
    case Request.get_requests_for_user(user.id, role: :responder, status: "pending", limit: 5) do
      {:ok, %{requests: requests}} -> requests
      _ -> []
    end
  end

  defp parse_filter("bots"), do: :bots
  defp parse_filter("users"), do: :users
  defp parse_filter(_), do: :all

  defp format_error(:insufficient_balance), do: "Insufficient balance to accept."
  defp format_error(:request_not_found), do: "Request not found."
  defp format_error(:not_responder), do: "You can't respond to this request."
  defp format_error(:request_not_pending), do: "Request is no longer pending."
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Failed: #{inspect(reason)}"

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

      <div class="mb-8">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-lg font-bold">Network</h2>
          <.link navigate={~p"/network"} class="text-sm text-gray-500">
            Full graph &rarr;
          </.link>
        </div>
        <div
          id="network-graph-preview"
          phx-hook="NetworkGraph"
          phx-update="ignore"
          data-graph={@network_json}
          data-compact="true"
          class="border border-gray-200 w-full"
        >
        </div>
      </div>

      <div :if={@pending_requests != []} class="mb-8">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-lg font-bold">Pending Requests</h2>
          <.link navigate={~p"/requests"} class="text-sm text-gray-500">
            View all &rarr;
          </.link>
        </div>

        <div class="border border-gray-200">
          <div
            :for={req <- @pending_requests}
            class="flex items-center justify-between px-4 py-3 border-b border-gray-200 last:border-b-0"
          >
            <div class="flex items-center gap-2">
              <.link navigate={~p"/user/#{req.requester.id}"} class="font-medium">
                {req.requester.username}
              </.link>
              <span class="text-sm text-gray-500">requests</span>
              <span class="font-mono text-sm font-bold">{req.amount} STK</span>
            </div>
            <div class="flex items-center gap-2">
              <button
                phx-click="accept_request"
                phx-value-id={req.id}
                class="border border-black px-3 py-1 text-xs font-bold"
              >
                Accept
              </button>
              <button
                phx-click="deny_request"
                phx-value-id={req.id}
                class="border border-gray-300 px-3 py-1 text-xs text-gray-500"
              >
                Deny
              </button>
            </div>
          </div>
        </div>
      </div>

      <div :if={@current_user && @pending_requests == []} class="mb-8 text-right">
        <.link navigate={~p"/requests"} class="text-sm text-gray-500">
          Your Requests &rarr;
        </.link>
      </div>

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
            <span
              :if={@current_user && @current_user.id == user.id}
              class="text-xs uppercase tracking-wide text-gray-900 border border-black px-1"
            >
              YOU
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
