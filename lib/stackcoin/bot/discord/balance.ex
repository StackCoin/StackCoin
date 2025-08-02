defmodule StackCoin.Bot.Discord.Balance do
  @moduledoc """
  Discord balance command implementation.
  """

  alias StackCoin.Core.Bank
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType

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
    with {:ok, guild} <- Bank.get_guild_by_discord_id(interaction.guild_id),
         {:ok, _channel_check} <- Bank.validate_channel(guild, interaction.channel_id),
         {:ok, user} <- Bank.get_user_by_discord_id(interaction.user.id) do
      send_balance_response(interaction, user)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp send_balance_response(interaction, user) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} You have #{user.balance} StackCoins",
            color: Commands.stackcoin_color()
          }
        ]
      }
    })
  end
end
