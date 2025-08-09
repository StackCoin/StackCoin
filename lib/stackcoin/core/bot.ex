defmodule StackCoin.Core.Bot do
  @moduledoc """
  Bot user management operations.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema
  alias StackCoin.Core.User
  import Ecto.Query

  @doc """
  Admin-only bot creation with permission check.
  """
  def admin_create_bot_user(admin_discord_snowflake, bot_name) do
    with {:ok, _admin_check} <- User.check_admin_permissions(admin_discord_snowflake) do
      create_bot_user(admin_discord_snowflake, bot_name)
    else
      {:error, :not_admin} -> {:error, :not_admin}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a new bot user for the given owner.
  Creates both a User record and a BotUser record.
  """
  def create_bot_user(owner_discord_snowflake, bot_name) do
    with {:ok, owner} <- User.get_user_by_discord_id(owner_discord_snowflake) do
      Repo.transaction(fn ->
        # Create the user record for the bot
        user_attrs = %{
          username: bot_name,
          balance: 0,
          admin: false,
          banned: false
        }

        with {:ok, bot_user} <- Repo.insert(Schema.User.changeset(%Schema.User{}, user_attrs)) do
          # Create the bot record
          token = Schema.BotUser.generate_token()

          bot_attrs = %{
            name: bot_name,
            token: token,
            user_id: bot_user.id,
            owner_id: owner.id,
            active: true
          }

          case Repo.insert(Schema.BotUser.changeset(%Schema.BotUser{}, bot_attrs)) do
            {:ok, bot} ->
              # Preload the user for the response
              Repo.preload(bot, [:user, :owner])

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets all bot users for a given owner.
  """
  def get_user_bots(owner_discord_snowflake) do
    with {:ok, owner} <- User.get_user_by_discord_id(owner_discord_snowflake) do
      query =
        from(b in Schema.BotUser,
          where: b.owner_id == ^owner.id and b.active == true,
          preload: [:user],
          select: b
        )

      {:ok, Repo.all(query)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resets a bot user's token.
  """
  def reset_bot_token(owner_discord_snowflake, bot_id) do
    with {:ok, owner} <- User.get_user_by_discord_id(owner_discord_snowflake),
         {:ok, bot} <- get_bot_by_id_and_owner(bot_id, owner.id) do
      new_token = Schema.BotUser.generate_token()

      case bot
           |> Schema.BotUser.changeset(%{token: new_token})
           |> Repo.update() do
        {:ok, updated_bot} -> {:ok, Repo.preload(updated_bot, :user)}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes (deactivates) a bot user.
  """
  def delete_bot_user(owner_discord_snowflake, bot_id) do
    with {:ok, owner} <- User.get_user_by_discord_id(owner_discord_snowflake),
         {:ok, bot} <- get_bot_by_id_and_owner(bot_id, owner.id) do
      case bot
           |> Schema.BotUser.changeset(%{active: false})
           |> Repo.update() do
        {:ok, updated_bot} -> {:ok, Repo.preload(updated_bot, :user)}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets a bot user by token for authentication.
  """
  def get_bot_by_token(token) do
    case Repo.get_by(Schema.BotUser, token: token, active: true) do
      nil -> {:error, :invalid_token}
      bot -> {:ok, Repo.preload(bot, [:user, :owner])}
    end
  end

  @doc """
  Gets a bot user by name.
  """
  def get_bot_by_name(bot_name) do
    case Repo.get_by(Schema.BotUser, name: bot_name, active: true) do
      nil -> {:error, :bot_not_found}
      bot -> {:ok, Repo.preload(bot, [:user, :owner])}
    end
  end

  @doc """
  Gets all active bot names for autocomplete.
  """
  def get_all_bot_names do
    query =
      from(b in Schema.BotUser,
        where: b.active == true,
        select: b.name,
        order_by: [asc: b.name]
      )

    Repo.all(query)
  end

  @doc """
  Gets bot owner information for a given user ID.
  Returns the bot user record and owner display name (with Discord mention if available).
  """
  def get_bot_owner_info(user_id) do
    query =
      from(bu in Schema.BotUser,
        join: owner in Schema.User,
        on: bu.owner_id == owner.id,
        left_join: du in Schema.DiscordUser,
        on: owner.id == du.id,
        where: bu.user_id == ^user_id and bu.active == true,
        select: {bu, owner, du}
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_bot_user}

      {bot_user, owner, discord_user} ->
        owner_display =
          case discord_user do
            nil -> owner.username
            du -> "<@#{du.snowflake}>"
          end

        {:ok, {bot_user, owner_display}}
    end
  end

  defp get_bot_by_id_and_owner(bot_id, owner_id) do
    case Repo.get_by(Schema.BotUser, id: bot_id, owner_id: owner_id, active: true) do
      nil -> {:error, :bot_not_found}
      bot -> {:ok, bot}
    end
  end
end
