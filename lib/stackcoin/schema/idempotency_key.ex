defmodule StackCoin.Schema.IdempotencyKey do
  use Ecto.Schema
  import Ecto.Changeset

  schema "idempotency_keys" do
    field(:key, :string)
    field(:bot_id, :integer)
    field(:response_code, :integer)
    field(:response_body, :string)
    field(:inserted_at, :naive_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:key, :bot_id, :response_code, :response_body])
    |> validate_required([:key, :bot_id, :response_code, :response_body])
    |> unique_constraint([:bot_id, :key])
    |> foreign_key_constraint(:bot_id)
  end
end
