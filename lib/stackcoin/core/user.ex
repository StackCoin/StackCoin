defmodule StackCoin.Core.User do
  @moduledoc """
  User management operations.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema
  import Ecto.Query

  @doc """
  Gets a user by their Discord snowflake ID.
  """
  def get_user_by_discord_id(discord_snowflake) do
    query =
      from(du in Schema.DiscordUser,
        join: u in Schema.User,
        on: du.id == u.id,
        where: du.snowflake == ^to_string(discord_snowflake),
        select: u
      )

    case Repo.one(query) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by their internal user ID.
  """
  def get_user_by_id(user_id) do
    case Repo.get(Schema.User, user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Creates a new user account with Discord information.
  """
  def create_user_account(discord_snowflake, username, opts \\ []) do
    admin = Keyword.get(opts, :admin, false)
    balance = Keyword.get(opts, :balance, 0)

    Repo.transaction(fn ->
      user_attrs = %{
        username: username,
        balance: balance,
        admin: admin,
        banned: false
      }

      with {:ok, user} <- Repo.insert(Schema.User.changeset(%Schema.User{}, user_attrs)),
           discord_user_attrs = %{
             id: user.id,
             snowflake: to_string(discord_snowflake),
             last_updated: NaiveDateTime.utc_now()
           },
           {:ok, _discord_user} <-
             Repo.insert(Schema.DiscordUser.changeset(%Schema.DiscordUser{}, discord_user_attrs)) do
        user
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Checks if a user has admin permissions.
  """
  def is_user_admin?(discord_snowflake) do
    case get_user_by_discord_id(discord_snowflake) do
      {:ok, user} -> {:ok, user.admin}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if a Discord user has admin permissions, including config-based admin.
  Creates admin user if they don't exist and are configured as admin.
  """
  def check_admin_permissions(discord_snowflake) do
    admin_user_id = Application.get_env(:stackcoin, :admin_user_id)
    user_snowflake_str = to_string(discord_snowflake)

    cond do
      admin_user_id && user_snowflake_str == admin_user_id ->
        ensure_admin_user_exists(user_snowflake_str)
        {:ok, :admin}

      true ->
        case is_user_admin?(user_snowflake_str) do
          {:ok, true} -> {:ok, :admin}
          {:ok, false} -> {:error, :not_admin}
          {:error, :user_not_found} -> {:error, :not_admin}
        end
    end
  end

  @doc """
  Bans a user from StackCoin.
  """
  def ban_user(user) do
    user
    |> Schema.User.changeset(%{banned: true})
    |> Repo.update()
  end

  @doc """
  Unbans a user from StackCoin.
  """
  def unban_user(user) do
    user
    |> Schema.User.changeset(%{banned: false})
    |> Repo.update()
  end

  @doc """
  Checks if a user is banned.
  """
  def check_user_banned(user) do
    if user.banned do
      {:error, :user_banned}
    else
      {:ok, :not_banned}
    end
  end

  @doc """
  Checks if a recipient user is banned (different error for sending to banned users).
  """
  def check_recipient_banned(user) do
    if user.banned do
      {:error, :recipient_banned}
    else
      {:ok, :not_banned}
    end
  end

  @doc """
  Admin-only user banning with permission check.
  """
  def admin_ban_user(admin_discord_snowflake, target_discord_snowflake) do
    with {:ok, _admin_check} <- check_admin_permissions(admin_discord_snowflake),
         {:ok, target_user} <- get_user_by_discord_id(target_discord_snowflake) do
      ban_user(target_user)
    else
      {:error, :not_admin} -> {:error, :not_admin}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Admin-only user unbanning with permission check.
  """
  def admin_unban_user(admin_discord_snowflake, target_discord_snowflake) do
    with {:ok, _admin_check} <- check_admin_permissions(admin_discord_snowflake),
         {:ok, target_user} <- get_user_by_discord_id(target_discord_snowflake) do
      unban_user(target_user)
    else
      {:error, :not_admin} -> {:error, :not_admin}
      {:error, reason} -> {:error, reason}
    end
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
    with {:ok, _admin_check} <- check_admin_permissions(admin_discord_snowflake) do
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

  @max_limit 100

  @doc """
  Searches users with various filters and pagination.
  Options:
  - :username - filter by username (partial match)
  - :banned - filter by banned status (true/false)
  - :admin - filter by admin status (true/false)
  - :limit - number of results to return (max #{@max_limit})
  - :offset - number of results to skip
  """
  def search_users(opts \\ []) do
    limit = min(Keyword.get(opts, :limit, 10), @max_limit)
    offset = Keyword.get(opts, :offset, 0)
    username = Keyword.get(opts, :username)
    banned = Keyword.get(opts, :banned)
    admin = Keyword.get(opts, :admin)

    # Get total count for pagination metadata
    count_query = build_user_count_query(username, banned, admin)
    total_count = Repo.aggregate(count_query, :count, :id)

    # Get paginated results
    query = build_user_query(username, banned, admin, limit, offset)
    users = Repo.all(query)

    {:ok, %{users: users, total_count: total_count}}
  end

  defp build_user_count_query(username, banned, admin) do
    query = from(u in Schema.User)

    query
    |> apply_username_filter(username)
    |> apply_banned_filter(banned)
    |> apply_admin_filter(admin)
  end

  defp build_user_query(username, banned, admin, limit, offset) do
    query =
      from(u in Schema.User,
        order_by: [desc: u.balance, asc: u.username],
        limit: ^limit,
        offset: ^offset,
        select: %{
          id: u.id,
          username: u.username,
          balance: u.balance,
          admin: u.admin,
          banned: u.banned
        }
      )

    query
    |> apply_username_filter(username)
    |> apply_banned_filter(banned)
    |> apply_admin_filter(admin)
  end

  defp apply_username_filter(query, nil), do: query

  defp apply_username_filter(query, username) do
    from(u in query,
      where: like(fragment("LOWER(?)", u.username), ^"%#{String.downcase(username)}%")
    )
  end

  defp apply_banned_filter(query, nil), do: query

  defp apply_banned_filter(query, banned) do
    from(u in query, where: u.banned == ^banned)
  end

  defp apply_admin_filter(query, nil), do: query

  defp apply_admin_filter(query, admin) do
    from(u in query, where: u.admin == ^admin)
  end

  defp ensure_admin_user_exists(user_snowflake) do
    case get_user_by_discord_id(user_snowflake) do
      {:ok, _user} ->
        :ok

      {:error, :user_not_found} ->
        {:ok, username} = Nostrum.Api.User.get(user_snowflake)

        case create_user_account(user_snowflake, username, admin: true) do
          {:ok, _user} -> :ok
          {:error, _} -> :error
        end
    end
  end
end
