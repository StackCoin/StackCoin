defmodule StackCoin.Bot.Discord.Dole do
  @moduledoc """
  Discord dole command implementation.
  """

  alias StackCoin.Core.{Bank, Reserve}
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType

  @doc """
  Returns the command definition for the dole command.
  """
  def definition do
    %{
      name: "dole",
      description: "Receive daily dole from the reserve"
    }
  end

  @doc """
  Handles the dole command interaction.
  """
  def handle(interaction) do
    with {:ok, guild} <- Bank.get_guild_by_discord_id(interaction.guild_id),
         {:ok, _channel_check} <- Bank.validate_channel(guild, interaction.channel_id),
         {:ok, user} <- get_or_create_user(interaction.user),
         {:ok, transaction} <- Reserve.transfer_dole_to_user(user.id) do
      send_success_response(interaction, user, transaction)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp get_or_create_user(discord_user) do
    case Bank.get_user_by_discord_id(discord_user.id) do
      {:ok, user} ->
        {:ok, user}

      {:error, :user_not_found} ->
        username = discord_user.username || "User"
        Bank.create_user_account(discord_user.id, username)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_success_response(interaction, _user, transaction) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} Received #{transaction.amount} STK",
            description: "New Balance: **#{transaction.to_new_balance}** STK",
            color: Commands.stackcoin_color()
          }
        ]
      }
    })
  end
end
