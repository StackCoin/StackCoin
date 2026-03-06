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

    replay_limit = Event.page_size()

    if user_id == socket.assigns.user.id do
      last_event_id = Map.get(payload, "last_event_id")

      Phoenix.PubSub.subscribe(StackCoin.PubSub, "user:#{user_id}")

      case last_event_id do
        nil ->
          # No cursor — live events only, skip replay
          {:ok, socket}

        _ ->
          missed_count = Event.count_events_since(user_id, last_event_id)

          if missed_count > replay_limit do
            {:error,
             %{
               reason: "too_many_missed_events",
               missed_count: missed_count,
               replay_limit: replay_limit,
               message:
                 "Use GET /api/events?since_id=#{last_event_id} to catch up, then reconnect with a recent last_event_id"
             }}
          else
            send(self(), {:replay_events, last_event_id})
            {:ok, socket}
          end
      end
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
