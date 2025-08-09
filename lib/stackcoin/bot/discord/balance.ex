defmodule StackCoin.Bot.Discord.Balance do
  @moduledoc """
  Discord balance command implementation.
  """

  alias StackCoin.Core.{User, Bot, DiscordGuild}
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
      description: "Check StackCoin balances",
      options: [
        %{
          type: ApplicationCommandOptionType.user(),
          name: "user",
          description: "User whose balance to check",
          required: false
        },
        %{
          type: ApplicationCommandOptionType.string(),
          name: "bot",
          description: "Bot whose balance to check",
          required: false,
          autocomplete: true
        }
      ]
    }
  end

  @doc """
  Handles the balance command interaction.
  """
  def handle(interaction) do
    cond do
      interaction.type == Nostrum.Constants.InteractionType.application_command_autocomplete() ->
        handle_autocomplete(interaction)

      interaction.type == Nostrum.Constants.InteractionType.application_command() ->
        handle_command(interaction)

      true ->
        Commands.send_error_response(interaction, :unknown_interaction_type)
    end
  end

  defp handle_command(interaction) do
    with {:ok, guild} <- DiscordGuild.get_guild_by_discord_id(interaction.guild_id),
         {:ok, _channel_check} <- DiscordGuild.validate_channel(guild, interaction.channel_id),
         {:ok, {target, target_type, is_self}} <- get_target(interaction) do
      send_balance_response(interaction, target, target_type, is_self)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp handle_autocomplete(interaction) do
    focused_option = get_focused_option(interaction)

    case focused_option do
      %{name: "bot", value: partial_name} ->
        suggestions = get_bot_suggestions(partial_name)
        send_autocomplete_response(interaction, suggestions)

      _ ->
        send_autocomplete_response(interaction, [])
    end
  end

  defp get_target(interaction) do
    user_option = get_user_option(interaction)
    bot_option = get_bot_option(interaction)

    cond do
      user_option && bot_option ->
        {:error, :both_user_and_bot_specified}

      user_option ->
        # User specified, check their balance
        case User.get_user_by_discord_id(user_option) do
          {:ok, user} -> {:ok, {user, :user, false}}
          {:error, :user_not_found} -> {:error, :other_user_not_found}
          {:error, reason} -> {:error, reason}
        end

      bot_option ->
        # Bot specified, check their balance
        case Bot.get_bot_by_name(bot_option) do
          {:ok, bot} -> {:ok, {bot, :bot, false}}
          {:error, :bot_not_found} -> {:error, :bot_not_found}
          {:error, reason} -> {:error, reason}
        end

      true ->
        # No user or bot specified, check own balance
        case User.get_user_by_discord_id(interaction.user.id) do
          {:ok, user} ->
            case User.check_user_banned(user) do
              {:ok, :not_banned} -> {:ok, {user, :user, true}}
              {:error, :user_banned} -> {:error, :user_banned}
            end

          {:error, reason} ->
            {:error, reason}
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

  defp get_bot_option(interaction) do
    case interaction.data.options do
      nil ->
        nil

      options ->
        Enum.find_value(options, fn option ->
          if option.name == "bot", do: option.value, else: nil
        end)
    end
  end

  defp get_focused_option(interaction) do
    case interaction.data.options do
      nil ->
        nil

      options ->
        Enum.find(options, fn option ->
          Map.get(option, :focused, false)
        end)
    end
  end

  defp get_bot_suggestions(partial_name) do
    Bot.get_all_bot_names()
    |> Enum.filter(fn name ->
      String.contains?(String.downcase(name), String.downcase(partial_name))
    end)
    |> Enum.take(25)
    |> Enum.map(fn name ->
      %{name: name, value: name}
    end)
  end

  defp send_autocomplete_response(interaction, suggestions) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.application_command_autocomplete_result(),
      data: %{
        choices: suggestions
      }
    })
  end

  defp send_balance_response(interaction, target, target_type, is_self) do
    title =
      case {target_type, is_self} do
        {:user, true} ->
          "#{Commands.stackcoin_emoji()} Your balance: #{target.balance} STK"

        {:user, false} ->
          "#{Commands.stackcoin_emoji()} #{target.username}'s balance: #{target.balance} STK"

        {:bot, false} ->
          "#{Commands.stackcoin_emoji()} Bot #{target.name}'s balance: #{target.user.balance} STK"
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
