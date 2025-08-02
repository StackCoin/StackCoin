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
      description: "Receive your daily dole of 10 StackCoins from the reserve system"
    }
  end

  @doc """
  Handles the dole command interaction.
  """
  def handle(interaction) do
    with {:ok, guild} <- Bank.get_guild_by_discord_id(interaction.guild_id),
         {:ok, _channel_check} <- Bank.validate_channel(guild, interaction.channel_id),
         {:ok, user} <- Bank.get_user_by_discord_id(interaction.user.id),
         {:ok, transaction} <- Reserve.transfer_dole_to_user(user.id) do
      send_success_response(interaction, user, transaction)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp send_success_response(interaction, _user, transaction) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "💰 Daily Dole Received!",
            description:
              "You've received **#{transaction.amount}** StackCoins from the reserve system!",
            color: 0x00FF00,
            fields: [
              %{
                name: "Your New Balance",
                value: "**#{transaction.to_new_balance}** StackCoins",
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
