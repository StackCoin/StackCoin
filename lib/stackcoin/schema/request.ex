defmodule StackCoin.Schema.Request do
  use Ecto.Schema
  import Ecto.Changeset

  schema "request" do
    field(:status, :string)
    field(:amount, :integer)
    field(:requested_at, :naive_datetime)
    field(:resolved_at, :naive_datetime)
    field(:label, :string)

    belongs_to(:requester, StackCoin.Schema.User, foreign_key: :requester_id)
    belongs_to(:responder, StackCoin.Schema.User, foreign_key: :responder_id)
    belongs_to(:transaction, StackCoin.Schema.Transaction, foreign_key: :transaction_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :requester_id,
      :responder_id,
      :status,
      :amount,
      :requested_at,
      :resolved_at,
      :transaction_id,
      :label
    ])
    |> validate_required([:requester_id, :responder_id, :status, :amount, :requested_at])
    |> validate_inclusion(:status, ["pending", "accepted", "denied", "expired"])
    |> validate_number(:amount, greater_than: 0)
    |> validate_different_users()
  end

  defp validate_different_users(changeset) do
    requester_id = get_field(changeset, :requester_id)
    responder_id = get_field(changeset, :responder_id)

    if requester_id && responder_id && requester_id == responder_id do
      add_error(changeset, :responder_id, "cannot be the same as requester_id")
    else
      changeset
    end
  end
end
