defmodule StackCoin.Schema.Pump do
  use Ecto.Schema
  import Ecto.Changeset

  schema "pump" do
    field(:to_new_balance, :integer)
    field(:amount, :integer)
    field(:time, :naive_datetime)
    field(:label, :string)

    belongs_to(:signee, StackCoin.Schema.User, foreign_key: :signee_id)
    belongs_to(:to_internal_user, StackCoin.Schema.InternalUser, foreign_key: :to_id)
  end

  def changeset(pump, attrs) do
    pump
    |> cast(attrs, [:signee_id, :to_id, :to_new_balance, :amount, :time, :label])
    |> validate_required([:signee_id, :to_id, :to_new_balance, :amount, :time, :label])
    |> validate_number(:to_new_balance, greater_than_or_equal_to: 0)
    |> validate_number(:amount, greater_than_or_equal_to: 1)
    |> validate_different_users()
  end

  defp validate_different_users(changeset) do
    signee_id = get_field(changeset, :signee_id)
    to_id = get_field(changeset, :to_id)

    if signee_id && to_id && signee_id == to_id do
      add_error(changeset, :to_id, "cannot be the same as signee_id")
    else
      changeset
    end
  end
end
