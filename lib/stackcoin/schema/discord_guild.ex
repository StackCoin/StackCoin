defmodule StackCoin.Schema.DiscordGuild do
  use Ecto.Schema
  import Ecto.Changeset

  schema "discord_guild" do
    field(:snowflake, :string)
    field(:name, :string)
    field(:designated_channel_snowflake, :string)
    field(:last_updated, :naive_datetime)
  end

  def changeset(discord_guild, attrs) do
    discord_guild
    |> cast(attrs, [:snowflake, :name, :designated_channel_snowflake, :last_updated])
    |> validate_required([
      :snowflake,
      :name,
      :designated_channel_snowflake,
      :last_updated
    ])
    |> unique_constraint(:snowflake)
    |> unique_constraint(:designated_channel_snowflake)
  end
end
