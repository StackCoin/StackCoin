defmodule StackCoinWeb.EventController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StackCoin.Core.Event

  operation :index,
    operation_id: "stackcoin_events",
    summary: "Get events for the authenticated user",
    description:
      "Returns events since the given ID, ordered by ID ascending. Used for polling and cursor-based pagination.",
    parameters: [
      since_id: [
        in: :query,
        description: "Return events with ID greater than this value",
        type: :integer,
        example: 0,
        required: false
      ]
    ],
    responses: [
      ok: {"Events response", "application/json", StackCoinWeb.Schemas.EventsResponse}
    ]

  def index(conn, params) do
    user = conn.assigns.current_user
    since_id = parse_since_id(params)

    {events, has_more} = Event.list_events_since(user.id, since_id)

    json(conn, %{
      events: Enum.map(events, &Event.serialize_event/1),
      has_more: has_more
    })
  end

  defp parse_since_id(%{"since_id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp parse_since_id(_), do: 0
end
