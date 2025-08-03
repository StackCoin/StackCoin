defmodule StackCoin.Schema.BotUser do
  use Ecto.Schema
  import Ecto.Changeset

  schema "bot_user" do
    field(:token, :string)
    field(:active, :boolean, default: true)

    belongs_to(:user, StackCoin.Schema.User, foreign_key: :user_id)
    belongs_to(:owner, StackCoin.Schema.User, foreign_key: :owner_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(bot_user, attrs) do
    bot_user
    |> cast(attrs, [:token, :user_id, :owner_id, :active])
    |> validate_required([:token, :user_id, :owner_id])
    |> validate_length(:token, is: 32)
    |> unique_constraint(:token)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:owner_id)
  end

  def generate_token do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
