defmodule StackCoin.Core.Event do
  alias StackCoin.Repo
  alias StackCoin.Schema.Event
  alias StackCoin.Core.EventData
  import Ecto.Query

  def create_event(type, user_id, data) when is_binary(type) and is_map(data) do
    with {:ok, _validated} <- EventData.validate(type, data) do
      attrs = %{
        type: type,
        user_id: user_id,
        data: Jason.encode!(data),
        inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      }

      result =
        %Event{}
        |> Event.changeset(attrs)
        |> Repo.insert()

      case result do
        {:ok, event} ->
          if user_id do
            Phoenix.PubSub.broadcast(
              StackCoin.PubSub,
              "user:#{user_id}",
              {:event, serialize_event(event)}
            )
          end

          {:ok, event}

        error ->
          error
      end
    end
  end

  @events_page_size 100

  def page_size, do: @events_page_size

  def list_events_since(user_id, last_event_id, limit \\ @events_page_size) do
    rows =
      Event
      |> where([e], e.user_id == ^user_id and e.id > ^last_event_id)
      |> order_by([e], asc: e.id)
      |> limit(^(limit + 1))
      |> Repo.all()

    has_more = length(rows) > limit
    events = Enum.take(rows, limit)
    {events, has_more}
  end

  def count_events_since(user_id, last_event_id) do
    Event
    |> where([e], e.user_id == ^user_id and e.id > ^last_event_id)
    |> Repo.aggregate(:count)
  end

  def serialize_event(%Event{} = event) do
    %{
      id: event.id,
      type: event.type,
      data: Jason.decode!(event.data),
      inserted_at: NaiveDateTime.to_iso8601(event.inserted_at)
    }
  end
end
