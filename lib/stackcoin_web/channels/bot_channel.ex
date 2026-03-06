defmodule StackCoinWeb.BotChannel do
  use Phoenix.Channel

  alias StackCoin.Core.Event

  @impl true
  def join("user:" <> user_id_str, payload, socket) do
    user_id =
      case user_id_str do
        "self" -> socket.assigns.user.id
        id_str -> String.to_integer(id_str)
      end

    if user_id == socket.assigns.user.id do
      Phoenix.PubSub.subscribe(StackCoin.PubSub, "user:#{user_id}")

      last_event_id = Map.get(payload, "last_event_id", 0)
      send(self(), {:replay_events, last_event_id})
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:replay_events, last_event_id}, socket) do
    {events, _has_more} = Event.list_events_since(socket.assigns.user.id, last_event_id)

    for event <- events do
      push(socket, "event", Event.serialize_event(event))
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:event, event_data}, socket) do
    push(socket, "event", event_data)
    {:noreply, socket}
  end
end
