defmodule StackCoin.Schema.DiscordUser do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "discord_user" do
    field(:snowflake, :string)
    field(:last_updated, :naive_datetime)

    belongs_to(:user, StackCoin.Schema.User, define_field: false)
  end

  def changeset(discord_user, attrs) do
    discord_user
    |> cast(attrs, [:id, :snowflake, :last_updated])
    |> validate_required([:id, :snowflake, :last_updated])
    |> unique_constraint(:snowflake)
    |> foreign_key_constraint(:id, name: :discord_user_id_fkey)
  end
end
