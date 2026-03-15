defmodule StackCoinWeb.NetworkLive do
  use StackCoinWeb, :live_view

  alias StackCoin.NetworkCache

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "transactions")
    end

    {:ok, json} = NetworkCache.get_network_json()

    {:ok,
     socket
     |> assign(:network_json, json)
     |> assign(:show_reserve, false)
     |> assign(:page_title, "Network — StackCoin")}
  end

  @impl true
  def handle_event("toggle_reserve", _params, socket) do
    show = !socket.assigns.show_reserve

    {:noreply,
     socket
     |> assign(:show_reserve, show)
     |> push_event("toggle_reserve", %{show: show})}
  end

  @impl true
  def handle_info({:new_transaction, _transaction}, socket) do
    {:ok, json} = NetworkCache.get_network_json()
    {:noreply, assign(socket, :network_json, json)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>

      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Network</h1>
        <button
          phx-click="toggle_reserve"
          class={[
            "border px-3 py-1 text-xs",
            @show_reserve && "border-black font-bold",
            !@show_reserve && "border-gray-300 text-gray-500"
          ]}
        >
          <%= if @show_reserve, do: "Hide Reserve", else: "Show Reserve" %>
        </button>
      </div>
    </div>

    <div class="w-full px-4">
      <div
        id="network-graph"
        phx-hook="NetworkGraph"
        phx-update="ignore"
        data-graph={@network_json}
        data-compact="false"
        class="border border-gray-200 w-full"
      >
      </div>
    </div>
    """
  end
end
