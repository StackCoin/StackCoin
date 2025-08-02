defmodule StackCoin.Schema.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user" do
    field(:username, :string)
    field(:balance, :integer)
    field(:last_given_dole, :naive_datetime)
    field(:admin, :boolean, default: false)
    field(:banned, :boolean, default: false)

    has_one(:internal_user, StackCoin.Schema.InternalUser, foreign_key: :id)
    has_one(:discord_user, StackCoin.Schema.DiscordUser, foreign_key: :id)
    has_many(:transactions_from, StackCoin.Schema.Transaction, foreign_key: :from_id)
    has_many(:transactions_to, StackCoin.Schema.Transaction, foreign_key: :to_id)
    has_many(:pumps, StackCoin.Schema.Pump, foreign_key: :signee_id)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :balance, :last_given_dole, :admin, :banned])
    |> validate_required([:username, :balance, :admin, :banned])
    |> validate_number(:balance, greater_than_or_equal_to: 0)
  end
end
