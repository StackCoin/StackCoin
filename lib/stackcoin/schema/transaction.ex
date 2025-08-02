defmodule StackCoin.Schema.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transaction" do
    field(:from_new_balance, :integer)
    field(:to_new_balance, :integer)
    field(:amount, :integer)
    field(:time, :naive_datetime)
    field(:label, :string)

    belongs_to(:from_user, StackCoin.Schema.User, foreign_key: :from_id)
    belongs_to(:to_user, StackCoin.Schema.User, foreign_key: :to_id)
  end

  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:from_id, :from_new_balance, :to_id, :to_new_balance, :amount, :time, :label])
    |> validate_required([:from_id, :from_new_balance, :to_id, :to_new_balance, :amount, :time])
    |> validate_number(:from_new_balance, greater_than_or_equal_to: 0)
    |> validate_number(:to_new_balance, greater_than_or_equal_to: 0)
    |> validate_number(:amount, greater_than_or_equal_to: 1)
    |> validate_different_users()
  end

  defp validate_different_users(changeset) do
    from_id = get_field(changeset, :from_id)
    to_id = get_field(changeset, :to_id)

    if from_id && to_id && from_id == to_id do
      add_error(changeset, :to_id, "cannot be the same as from_id")
    else
      changeset
    end
  end
end
