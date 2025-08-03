defmodule StackCoin.Bot.Discord.Bot do
  @moduledoc """
  Discord bot management command implementation for all users.
  """

  alias StackCoin.Core.Bot
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Constants.{ApplicationCommandOptionType, InteractionCallbackType}

  @doc """
  Returns the command definition for the bot command.
  """
  def definition do
    %{
      name: "bot",
      description: "Bot management commands",
      options: [
        %{
          type: ApplicationCommandOptionType.sub_command(),
          name: "create",
          description: "Create a new bot user",
          options: [
            %{
              type: ApplicationCommandOptionType.string(),
              name: "name",
              description: "Name for the bot",
              required: true,
              max_length: 50
            }
          ]
        },
        %{
          type: ApplicationCommandOptionType.sub_command(),
          name: "list",
          description: "List your bot users"
        },
        %{
          type: ApplicationCommandOptionType.sub_command(),
          name: "reset-token",
          description: "Reset a bot's token",
          options: [
            %{
              type: ApplicationCommandOptionType.integer(),
              name: "bot_id",
              description: "ID of the bot to reset token for",
              required: true
            }
          ]
        },
        %{
          type: ApplicationCommandOptionType.sub_command(),
          name: "delete",
          description: "Delete a bot user",
          options: [
            %{
              type: ApplicationCommandOptionType.integer(),
              name: "bot_id",
              description: "ID of the bot to delete",
              required: true
            }
          ]
        }
      ]
    }
  end

  @doc """
  Handles the bot command interaction.
  """
  def handle(interaction) do
    with {:ok, subcommand} <- get_subcommand(interaction) do
      handle_subcommand(subcommand, interaction)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp get_subcommand(interaction) do
    case interaction.data.options do
      [%{name: subcommand_name} | _] -> {:ok, subcommand_name}
      _ -> {:error, :no_subcommand}
    end
  end

  defp handle_subcommand("create", interaction) do
    with {:ok, bot_name} <- get_bot_name(interaction) do
      create_bot(bot_name, interaction)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp handle_subcommand("list", interaction) do
    list_bots(interaction)
  end

  defp handle_subcommand("reset-token", interaction) do
    with {:ok, bot_id} <- get_bot_id(interaction) do
      reset_bot_token(bot_id, interaction)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp handle_subcommand("delete", interaction) do
    with {:ok, bot_id} <- get_bot_id(interaction) do
      delete_bot(bot_id, interaction)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp get_bot_name(interaction) do
    case get_option_value(interaction, "name") do
      nil -> {:error, :missing_name}
      name when is_binary(name) -> {:ok, name}
      _ -> {:error, :invalid_name}
    end
  end

  defp get_bot_id(interaction) do
    case get_option_value(interaction, "bot_id") do
      nil -> {:error, :missing_bot_id}
      bot_id when is_integer(bot_id) -> {:ok, bot_id}
      _ -> {:error, :invalid_bot_id}
    end
  end

  defp get_option_value(interaction, option_name) do
    case interaction.data.options do
      [%{options: sub_options} | _] ->
        Enum.find_value(sub_options, fn
          %{name: ^option_name, value: value} -> value
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp create_bot(bot_name, interaction) do
    case Bot.create_bot_user(interaction.user.id, bot_name) do
      {:ok, bot} ->
        send_bot_created_response(interaction, bot)

      {:error, changeset} ->
        Commands.send_error_response(
          interaction,
          "Failed to create bot: #{inspect(changeset.errors)}"
        )
    end
  end

  defp list_bots(interaction) do
    case Bot.get_user_bots(interaction.user.id) do
      {:ok, bots} ->
        send_bot_list_response(interaction, bots)

      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp reset_bot_token(bot_id, interaction) do
    case Bot.reset_bot_token(interaction.user.id, bot_id) do
      {:ok, bot} ->
        send_bot_token_reset_response(interaction, bot)

      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp delete_bot(bot_id, interaction) do
    case Bot.delete_bot_user(interaction.user.id, bot_id) do
      {:ok, bot} ->
        send_bot_deleted_response(interaction, bot)

      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp send_bot_created_response(interaction, bot) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} Bot Created Successfully!",
            description:
              "Bot **#{bot.user.username}** (ID: #{bot.id}) has been created.\n\nYour bot token will be sent to you via direct message.",
            color: Commands.stackcoin_color()
          }
        ]
      }
    })

    send_bot_token_dm(interaction.user.id, bot)
  end

  defp send_bot_list_response(interaction, bots) do
    bot_list =
      if Enum.empty?(bots) do
        "You have no active bots."
      else
        bots
        |> Enum.map(fn bot -> "• **#{bot.user.username}** (ID: #{bot.id})" end)
        |> Enum.join("\n")
      end

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} Your Bots",
            description: bot_list,
            color: Commands.stackcoin_color()
          }
        ]
      }
    })
  end

  defp send_bot_token_reset_response(interaction, bot) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} Bot Token Reset",
            description:
              "Token for bot **#{bot.user.username}** has been reset.\n\nYour new bot token will be sent to you via direct message.",
            color: Commands.stackcoin_color()
          }
        ]
      }
    })

    send_bot_token_dm(interaction.user.id, bot)
  end

  defp send_bot_deleted_response(interaction, bot) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} Bot Deleted",
            description: "Bot **#{bot.user.username}** has been deleted.",
            color: Commands.stackcoin_color()
          }
        ]
      }
    })
  end

  defp send_bot_token_dm(user_id, bot) do
    Api.User.create_dm(user_id)
    |> case do
      {:ok, dm_channel} ->
        Api.Message.create(dm_channel.id, %{
          embeds: [
            %{
              title: "#{Commands.stackcoin_emoji()} Bot Token",
              description:
                "Here is the token for your bot **#{bot.user.username}**:\n\n```\n#{bot.token}\n```\n\n**Keep this token secure!** Use it in the `Authorization: Bearer <token>` header for API requests.",
              color: Commands.stackcoin_color()
            }
          ]
        })

      {:error, _reason} ->
        :error
    end
  end
end
