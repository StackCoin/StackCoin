defmodule StackCoin.Bot.Discord.Balance do
  @moduledoc """
  Discord balance command implementation.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema.{User, DiscordUser, DiscordGuild}
  alias Nostrum.Api
  import Ecto.Query

  @doc """
  Returns the command definition for the balance command.
  """
  def definition do
    %{
      name: "balance",
      description: "Check your StackCoin balance"
    }
  end

  @doc """
  Handles the balance command interaction.
  """
  def handle(interaction) do
    with {:ok, guild} <- get_guild(interaction.guild_id),
         {:ok, _channel_check} <- check_channel(interaction.channel_id, guild),
         {:ok, user} <- get_user(interaction.user.id) do
      send_balance_response(interaction, user)
    else
      {:error, :guild_not_registered} ->
        Api.create_interaction_response(interaction, %{
          type: 4,
          data: %{
            content: "❌ This server is not registered with StackCoin.",
            # Ephemeral
            flags: 64
          }
        })

      {:error, :wrong_channel} ->
        Api.create_interaction_response(interaction, %{
          type: 4,
          data: %{
            content: "❌ This command can only be used in the designated StackCoin channel.",
            # Ephemeral
            flags: 64
          }
        })

      {:error, :user_not_found} ->
        Api.create_interaction_response(interaction, %{
          type: 4,
          data: %{
            content:
              "❌ You don't have a StackCoin account yet. Use other commands to get started!",
            # Ephemeral
            flags: 64
          }
        })

      {:error, reason} ->
        Api.create_interaction_response(interaction, %{
          type: 4,
          data: %{
            content: "❌ An error occurred: #{inspect(reason)}",
            # Ephemeral
            flags: 64
          }
        })
    end
  end

  defp get_guild(guild_id) when is_nil(guild_id), do: {:error, :no_guild}

  defp get_guild(guild_id) do
    case Repo.get_by(DiscordGuild, snowflake: to_string(guild_id)) do
      nil -> {:error, :guild_not_registered}
      guild -> {:ok, guild}
    end
  end

  defp check_channel(channel_id, guild) do
    if to_string(channel_id) == guild.designated_channel_snowflake do
      {:ok, :channel_valid}
    else
      {:error, :wrong_channel}
    end
  end

  defp get_user(user_snowflake) do
    query =
      from(du in DiscordUser,
        join: u in User,
        on: du.id == u.id,
        where: du.snowflake == ^to_string(user_snowflake),
        select: u
      )

    case Repo.one(query) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp send_balance_response(interaction, user) do
    Api.create_interaction_response(interaction, %{
      type: 4,
      data: %{
        embeds: [
          %{
            title: "💰 Your StackCoin Balance",
            description: "**#{user.balance}** StackCoins",
            color: 0x00FF00,
            fields: [
              %{
                name: "Username",
                value: user.username,
                inline: true
              },
              %{
                name: "Account Status",
                value: if(user.banned, do: "🚫 Banned", else: "✅ Active"),
                inline: true
              }
            ],
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ]
      }
    })
  end
end
