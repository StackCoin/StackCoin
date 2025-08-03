defmodule StackCoin.Core.Bot do
  @moduledoc """
  Bot user management operations.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema
  alias StackCoin.Core.User
  import Ecto.Query

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

  defp get_bot_by_id_and_owner(bot_id, owner_id) do
    case Repo.get_by(Schema.BotUser, id: bot_id, owner_id: owner_id, active: true) do
      nil -> {:error, :bot_not_found}
      bot -> {:ok, bot}
    end
  end
end
