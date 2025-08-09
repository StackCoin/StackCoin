defmodule StackCoin.Core.DiscordGuild do
  @moduledoc """
  Discord guild management operations.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema
  alias StackCoin.Core.User
  import Ecto.Query

  @max_limit 100

  @doc """
  Searches Discord guilds with various filters and pagination.
  Options:
  - :name - filter by guild name (partial match)
  - :snowflake - filter by Discord snowflake ID
  - :limit - number of results to return (max #{@max_limit})
  - :offset - number of results to skip
  """
  def search_guilds(opts \\ []) do
    limit = min(Keyword.get(opts, :limit, 10), @max_limit)
    offset = Keyword.get(opts, :offset, 0)
    name = Keyword.get(opts, :name)
    snowflake = Keyword.get(opts, :snowflake)

    # Get total count for pagination metadata
    count_query = build_guild_count_query(name, snowflake)
    total_count = Repo.aggregate(count_query, :count, :id)

    # Get paginated results
    query = build_guild_query(name, snowflake, limit, offset)
    guilds = Repo.all(query)

    {:ok, %{guilds: guilds, total_count: total_count}}
  end

  defp build_guild_count_query(name, snowflake) do
    query = from(g in Schema.DiscordGuild)

    query
    |> apply_name_filter(name)
    |> apply_snowflake_filter(snowflake)
  end

  defp build_guild_query(name, snowflake, limit, offset) do
    query =
      from(g in Schema.DiscordGuild,
        order_by: [asc: g.name],
        limit: ^limit,
        offset: ^offset,
        select: %{
          id: g.id,
          snowflake: g.snowflake,
          name: g.name,
          designated_channel_snowflake: g.designated_channel_snowflake,
          last_updated: g.last_updated
        }
      )

    query
    |> apply_name_filter(name)
    |> apply_snowflake_filter(snowflake)
  end

  defp apply_name_filter(query, nil), do: query

  defp apply_name_filter(query, name) do
    from(g in query,
      where: like(fragment("LOWER(?)", g.name), ^"%#{String.downcase(name)}%")
    )
  end

  defp apply_snowflake_filter(query, nil), do: query

  defp apply_snowflake_filter(query, snowflake) do
    from(g in query, where: g.snowflake == ^to_string(snowflake))
  end

  @doc """
  Gets a guild by its Discord snowflake ID.
  """
  def get_guild_by_discord_id(guild_snowflake) do
    case Repo.get_by(Schema.DiscordGuild, snowflake: to_string(guild_snowflake)) do
      nil -> {:error, :guild_not_registered}
      guild -> {:ok, guild}
    end
  end

  @doc """
  Creates or updates a guild registration.
  Returns {:ok, {guild, :created}} or {:ok, {guild, :updated}} on success.
  """
  def register_guild(guild_snowflake, name, channel_snowflake) do
    guild_attrs = %{
      snowflake: to_string(guild_snowflake),
      name: name,
      designated_channel_snowflake: to_string(channel_snowflake),
      last_updated: NaiveDateTime.utc_now()
    }

    case Repo.get_by(Schema.DiscordGuild, snowflake: to_string(guild_snowflake)) do
      nil ->
        case Repo.insert(Schema.DiscordGuild.changeset(%Schema.DiscordGuild{}, guild_attrs)) do
          {:ok, guild} -> {:ok, {guild, :created}}
          {:error, changeset} -> {:error, changeset}
        end

      existing_guild ->
        case Repo.update(Schema.DiscordGuild.changeset(existing_guild, guild_attrs)) do
          {:ok, guild} -> {:ok, {guild, :updated}}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Admin-only guild registration with permission check.
  """
  def admin_register_guild(admin_discord_snowflake, guild_snowflake, name, channel_snowflake) do
    with {:ok, _admin_check} <- User.check_admin_permissions(admin_discord_snowflake) do
      register_guild(guild_snowflake, name, channel_snowflake)
    else
      {:error, :not_admin} -> {:error, :not_admin}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if a channel is the designated StackCoin channel for a guild.
  """
  def validate_channel(guild, channel_id) do
    if to_string(channel_id) == guild.designated_channel_snowflake do
      {:ok, :valid}
    else
      {:error, {:wrong_channel, guild}}
    end
  end
end
