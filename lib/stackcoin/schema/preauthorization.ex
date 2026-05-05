defmodule StackCoin.Schema.Preauthorization do
  use Ecto.Schema
  import Ecto.Changeset

  schema "preauthorization" do
    field(:max_amount, :integer)
    field(:window_hours, :integer)
    field(:status, :string)
    field(:requested_at, :naive_datetime)
    field(:approved_at, :naive_datetime)
    field(:revoked_at, :naive_datetime)

    belongs_to(:bot_user, StackCoin.Schema.User, foreign_key: :bot_user_id)
    belongs_to(:user, StackCoin.Schema.User, foreign_key: :user_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(preauth, attrs) do
    preauth
    |> cast(attrs, [
      :bot_user_id,
      :user_id,
      :max_amount,
      :window_hours,
      :status,
      :requested_at,
      :approved_at,
      :revoked_at
    ])
    |> validate_required([:bot_user_id, :user_id, :max_amount, :window_hours, :status, :requested_at])
    |> validate_inclusion(:status, ["pending", "active", "revoked"])
    |> validate_number(:max_amount, greater_than: 0)
    |> validate_number(:window_hours, greater_than: 0)
    |> validate_different_users()
  end

  defp validate_different_users(changeset) do
    bot_user_id = get_field(changeset, :bot_user_id)
    user_id = get_field(changeset, :user_id)

    if bot_user_id && user_id && bot_user_id == user_id do
      add_error(changeset, :user_id, "cannot be the same as bot_user_id")
    else
      changeset
    end
  end
end
