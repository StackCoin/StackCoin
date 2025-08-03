defmodule StackCoin.Bot.Discord.Send do
  @moduledoc """
  Discord send command implementation.
  """

  alias StackCoin.Core.{Bank, User}
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType
  alias Nostrum.Constants.ApplicationCommandOptionType

  @doc """
  Returns the command definition for the send command.
  """
  def definition do
    %{
      name: "send",
      description: "Send STK to another user",
      options: [
        %{
          type: ApplicationCommandOptionType.user(),
          name: "user",
          description: "User to send STK to",
          required: true
        },
        %{
          type: ApplicationCommandOptionType.integer(),
          name: "amount",
          description: "Amount of STK to send",
          required: true,
          min_value: 1
        }
      ]
    }
  end

  @doc """
  Handles the send command interaction.
  """
  def handle(interaction) do
    with {:ok, guild} <- User.get_guild_by_discord_id(interaction.guild_id),
         {:ok, _channel_check} <- User.validate_channel(guild, interaction.channel_id),
         {:ok, from_user} <- User.get_user_by_discord_id(interaction.user.id),
         {:ok, {to_user_id, amount}} <- parse_command_options(interaction),
         {:ok, to_user} <- get_recipient_user(to_user_id),
         {:ok, transaction} <-
           Bank.transfer_between_users(from_user.id, to_user.id, amount, "via /send") do
      send_success_response(interaction, from_user, to_user, transaction)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp parse_command_options(interaction) do
    case interaction.data.options do
      nil ->
        {:error, :missing_options}

      options ->
        user_id = get_option_value(options, "user")
        amount = get_option_value(options, "amount")

        if user_id && amount do
          {:ok, {user_id, amount}}
        else
          {:error, :missing_options}
        end
    end
  end

  defp get_option_value(options, name) do
    Enum.find_value(options, fn option ->
      if option.name == name, do: option.value, else: nil
    end)
  end

  defp get_recipient_user(to_user_id) do
    case User.get_user_by_discord_id(to_user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :user_not_found} -> {:error, :recipient_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_success_response(interaction, from_user, to_user, transaction) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} Transfer Successful",
            description:
              "#{from_user.username} (**#{transaction.from_new_balance} STK**) sent **#{transaction.amount} STK** to #{to_user.username} (**#{transaction.to_new_balance} STK**)",
            color: Commands.stackcoin_color()
          }
        ]
      }
    })
  end
end
