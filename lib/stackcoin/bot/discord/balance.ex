defmodule StackCoin.Bot.Discord.Balance do
  @moduledoc """
  Discord balance command implementation.
  """

  alias StackCoin.Core.Bank
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType
  alias Nostrum.Constants.ApplicationCommandOptionType

  @doc """
  Returns the command definition for the balance command.
  """
  def definition do
    %{
      name: "balance",
      description: "Check your StackCoin balance or another user's balance",
      options: [
        %{
          type: ApplicationCommandOptionType.user(),
          name: "user",
          description: "User whose balance to check (optional)",
          required: false
        }
      ]
    }
  end

  @doc """
  Handles the balance command interaction.
  """
  def handle(interaction) do
    with {:ok, guild} <- Bank.get_guild_by_discord_id(interaction.guild_id),
         {:ok, _channel_check} <- Bank.validate_channel(guild, interaction.channel_id),
         {:ok, {target_user, is_self}} <- get_target_user(interaction) do
      send_balance_response(interaction, target_user, is_self)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp get_target_user(interaction) do
    case get_user_option(interaction) do
      nil ->
        # No user specified, check own balance
        case Bank.get_user_by_discord_id(interaction.user.id) do
          {:ok, user} ->
            case Bank.check_user_banned(user) do
              {:ok, :not_banned} -> {:ok, {user, true}}
              {:error, :user_banned} -> {:error, :user_banned}
            end

          {:error, reason} ->
            {:error, reason}
        end

      target_user_id ->
        # User specified, check their balance
        case Bank.get_user_by_discord_id(target_user_id) do
          {:ok, user} -> {:ok, {user, false}}
          {:error, :user_not_found} -> {:error, :other_user_not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp get_user_option(interaction) do
    case interaction.data.options do
      nil ->
        nil

      options ->
        Enum.find_value(options, fn option ->
          if option.name == "user", do: option.value, else: nil
        end)
    end
  end

  defp send_balance_response(interaction, user, is_self) do
    title =
      if is_self do
        "#{Commands.stackcoin_emoji()} Your balance: #{user.balance} STK"
      else
        "#{Commands.stackcoin_emoji()} #{user.username}'s balance: #{user.balance} STK"
      end

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: title,
            color: Commands.stackcoin_color()
          }
        ]
      }
    })
  end
end
