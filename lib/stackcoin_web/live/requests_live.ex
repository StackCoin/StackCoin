defmodule StackCoinWeb.RequestsLive do
  use StackCoinWeb, :live_view

  alias StackCoin.Core.Request

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    current_user = socket.assigns[:current_user]

    if current_user == nil do
      {:noreply,
       socket
       |> put_flash(:error, "You must be logged in to view requests.")
       |> push_navigate(to: ~p"/")}
    else
      filter = parse_filter(params["filter"])
      page = parse_page(params["page"])
      offset = (page - 1) * @per_page

      status = if filter == :pending, do: "pending", else: nil

      {:ok, %{requests: requests, total_count: total_count}} =
        Request.get_requests_for_user(current_user.id,
          status: status,
          limit: @per_page,
          offset: offset
        )

      total_pages = max(ceil(total_count / @per_page), 1)

      {:noreply,
       socket
       |> assign(:requests, requests)
       |> assign(:filter, filter)
       |> assign(:current_page, page)
       |> assign(:total_pages, total_pages)
       |> assign(:page_title, "Requests — StackCoin")}
    end
  end

  @impl true
  def handle_event("accept_request", %{"id" => request_id}, socket) do
    current_user = socket.assigns.current_user

    case Request.accept_request(String.to_integer(request_id), current_user.id) do
      {:ok, _} ->
        {:noreply, socket |> reload_requests() |> put_flash(:info, "Request accepted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("deny_request", %{"id" => request_id}, socket) do
    current_user = socket.assigns.current_user

    case Request.deny_request(String.to_integer(request_id), current_user.id) do
      {:ok, _} ->
        {:noreply, socket |> reload_requests() |> put_flash(:info, "Request denied.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  @impl true
  def handle_info({:new_transaction, _transaction}, socket) do
    {:noreply, reload_requests(socket)}
  end

  defp reload_requests(socket) do
    current_user = socket.assigns.current_user
    filter = socket.assigns.filter
    page = socket.assigns.current_page
    offset = (page - 1) * @per_page
    status = if filter == :pending, do: "pending", else: nil

    {:ok, %{requests: requests, total_count: total_count}} =
      Request.get_requests_for_user(current_user.id,
        status: status,
        limit: @per_page,
        offset: offset
      )

    total_pages = max(ceil(total_count / @per_page), 1)

    socket
    |> assign(:requests, requests)
    |> assign(:total_pages, total_pages)
  end

  defp parse_filter("all"), do: :all
  defp parse_filter(_), do: :pending

  defp parse_page(nil), do: 1

  defp parse_page(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp patch_url(assigns) do
    fn page ->
      case assigns.filter do
        :all -> ~p"/requests?filter=all&page=#{page}"
        _ -> ~p"/requests?page=#{page}"
      end
    end
  end

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
    assigns = assign(assigns, :patch_url_fn, patch_url(assigns))

    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>

      <h1 class="text-2xl font-bold mb-4">Requests</h1>

      <nav class="flex gap-6 mb-6 border-b border-gray-200">
        <.link
          patch={~p"/requests"}
          class={[
            "pb-2 text-sm",
            @filter == :pending && "border-b-2 border-black font-bold"
          ]}
        >
          Pending
        </.link>
        <.link
          patch={~p"/requests?filter=all"}
          class={[
            "pb-2 text-sm",
            @filter == :all && "border-b-2 border-black font-bold"
          ]}
        >
          All
        </.link>
      </nav>

      <div class="border border-gray-200">
        <div
          :for={req <- @requests}
          class="flex items-center justify-between px-4 py-3 border-b border-gray-200 last:border-b-0"
        >
          <div class="flex items-center gap-2">
            <span class="font-mono text-sm font-bold">{req.amount} STK</span>
            <span class="text-sm">
              <.link navigate={~p"/user/#{req.requester.id}"}>{req.requester.username}</.link>
              &rarr;
              <.link navigate={~p"/user/#{req.responder.id}"}>{req.responder.username}</.link>
            </span>
            <span class={[
              "text-xs uppercase tracking-wide px-1 border",
              req.status == "pending" && "text-gray-500 border-gray-300",
              req.status == "accepted" && "text-green-700 border-green-300",
              req.status == "denied" && "text-red-700 border-red-300"
            ]}>
              {req.status}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <%= if req.status == "pending" && req.responder.id == @current_user.id do %>
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
            <% else %>
              <% {short, full} = format_time(req.requested_at) %>
              <time
                :if={full}
                datetime={NaiveDateTime.to_iso8601(req.requested_at)}
                title={full}
                class="text-sm text-gray-500"
              >
                {short}
              </time>
            <% end %>
          </div>
        </div>

        <div :if={@requests == []} class="px-4 py-8 text-center text-gray-500">
          No requests found.
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
