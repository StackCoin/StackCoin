defmodule StackCoin.Schema.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "events" do
    field(:type, :string)
    field(:user_id, :integer)
    field(:data, :string)
    field(:inserted_at, :naive_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :user_id, :data])
    |> validate_required([:type, :data])
  end
end
