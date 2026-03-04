defmodule StackCoinWeb.EventController do
  use StackCoinWeb, :controller

  alias StackCoin.Core.Event

  def index(conn, params) do
    user = conn.assigns.current_user
    since_id = parse_since_id(params)

    events =
      Event.list_events_since(user.id, since_id)
      |> Enum.map(&Event.serialize_event/1)

    json(conn, %{events: events})
  end

  defp parse_since_id(%{"since_id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp parse_since_id(_), do: 0
end
