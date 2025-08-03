defmodule StackCoin.Core.Bank do
  @moduledoc """
  Core banking operations and user/guild management.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema.{User, DiscordUser, DiscordGuild, Transaction}
  import Ecto.Query

  @doc """
  Gets a user by their Discord snowflake ID.
  """
  def get_user_by_discord_id(discord_snowflake) do
    query =
      from(du in DiscordUser,
        join: u in User,
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
    case Repo.get(User, user_id) do
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

      with {:ok, user} <- Repo.insert(User.changeset(%User{}, user_attrs)),
           discord_user_attrs = %{
             id: user.id,
             snowflake: to_string(discord_snowflake),
             last_updated: NaiveDateTime.utc_now()
           },
           {:ok, _discord_user} <-
             Repo.insert(DiscordUser.changeset(%DiscordUser{}, discord_user_attrs)) do
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
  Gets a guild by its Discord snowflake ID.
  """
  def get_guild_by_discord_id(guild_snowflake) do
    case Repo.get_by(DiscordGuild, snowflake: to_string(guild_snowflake)) do
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

    case Repo.get_by(DiscordGuild, snowflake: to_string(guild_snowflake)) do
      nil ->
        case Repo.insert(DiscordGuild.changeset(%DiscordGuild{}, guild_attrs)) do
          {:ok, guild} -> {:ok, {guild, :created}}
          {:error, changeset} -> {:error, changeset}
        end

      existing_guild ->
        case Repo.update(DiscordGuild.changeset(existing_guild, guild_attrs)) do
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
  Checks if a channel is the designated StackCoin channel for a guild.
  """
  def validate_channel(guild, channel_id) do
    if to_string(channel_id) == guild.designated_channel_snowflake do
      {:ok, :valid}
    else
      {:error, {:wrong_channel, guild}}
    end
  end

  @doc """
  Creates a transaction between two users.
  Updates both user balances and creates a transaction record.
  """
  def transfer_between_users(from_user_id, to_user_id, amount, label \\ nil) do
    Repo.transaction(fn ->
      with {:ok, _amount_check} <- validate_transfer_amount(amount),
           {:ok, _self_check} <- validate_not_self_transfer(from_user_id, to_user_id),
           {:ok, from_user} <- get_user_by_id(from_user_id),
           {:ok, to_user} <- get_user_by_id(to_user_id),
           {:ok, _from_banned_check} <- check_user_banned(from_user),
           {:ok, _to_banned_check} <- check_recipient_banned(to_user),
           {:ok, _balance_check} <- check_sufficient_balance(from_user, amount),
           {:ok, transaction} <- create_transaction(from_user, to_user, amount, label) do
        transaction
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Gets the balance of a user.
  """
  def get_user_balance(user_id) do
    case get_user_by_id(user_id) do
      {:ok, user} -> {:ok, user.balance}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates a user's balance directly.
  """
  def update_user_balance(user_id, new_balance) do
    case get_user_by_id(user_id) do
      {:ok, user} ->
        user
        |> User.changeset(%{balance: new_balance})
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Bans a user from the StackCoin system.
  """
  def ban_user(user) do
    user
    |> User.changeset(%{banned: true})
    |> Repo.update()
  end

  @doc """
  Unbans a user from the StackCoin system.
  """
  def unban_user(user) do
    user
    |> User.changeset(%{banned: false})
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

  defp validate_transfer_amount(amount) when amount <= 0, do: {:error, :invalid_amount}
  defp validate_transfer_amount(_amount), do: {:ok, :valid}

  defp validate_not_self_transfer(from_id, to_id) when from_id == to_id,
    do: {:error, :self_transfer}

  defp validate_not_self_transfer(_from_id, _to_id), do: {:ok, :valid}

  defp check_sufficient_balance(user, amount) do
    if user.balance >= amount do
      {:ok, :sufficient}
    else
      {:error, :insufficient_balance}
    end
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

  defp create_transaction(from_user, to_user, amount, label) do
    new_from_balance = from_user.balance - amount
    new_to_balance = to_user.balance + amount

    transaction_attrs = %{
      from_id: from_user.id,
      from_new_balance: new_from_balance,
      to_id: to_user.id,
      to_new_balance: new_to_balance,
      amount: amount,
      time: NaiveDateTime.utc_now(),
      label: label
    }

    with {:ok, transaction} <-
           Repo.insert(Transaction.changeset(%Transaction{}, transaction_attrs)),
         {:ok, _from_user} <- update_user_balance(from_user.id, new_from_balance),
         {:ok, _to_user} <- update_user_balance(to_user.id, new_to_balance) do
      {:ok, transaction}
    else
      {:error, changeset} -> {:error, changeset}
    end
  end
end
