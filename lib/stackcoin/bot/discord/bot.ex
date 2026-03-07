defmodule StackCoin.Bot.Discord.Bot do
  @moduledoc """
  Discord bot management command implementation for all users.
  """

  require Logger

  alias StackCoin.Core.{Bot, DiscordGuild}
  alias StackCoin.Bot.Discord.Commands
  alias StackCoin.Bot.Discord.Components
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
    with {:ok, guild} <- DiscordGuild.get_guild_by_discord_id(interaction.guild_id),
         {:ok, _channel_check} <- DiscordGuild.validate_channel(guild, interaction.channel_id),
         {:ok, subcommand} <- get_subcommand(interaction) do
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
    case Bot.admin_create_bot_user(interaction.user.id, bot_name) do
      {:ok, bot} ->
        send_bot_created_response(interaction, bot)

      {:error, :not_admin} ->
        case StackCoin.Core.User.get_user_by_discord_id(interaction.user.id) do
          {:ok, _user} ->
            send_bot_creation_request(bot_name, interaction)

          {:error, :user_not_found} ->
            Commands.send_error_response(interaction, :user_not_found)
        end

      {:error, changeset} ->
        Commands.send_error_response(interaction, changeset)
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
              "Bot **#{bot.name}** (ID: #{bot.id}) has been created.\n\nYour bot token will be sent to you via direct message.",
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
        |> Enum.map(fn bot -> "• **#{bot.name}** (ID: #{bot.id})" end)
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
              "Token for bot **#{bot.name}** has been reset.\n\nYour new bot token will be sent to you via direct message.",
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
            description: "Bot **#{bot.name}** has been deleted.",
            color: Commands.stackcoin_color()
          }
        ]
      }
    })
  end

  @doc """
  Handles a bot creation approval/rejection button interaction.
  Called from the Discord message component handler.
  """
  def handle_bot_creation_interaction(interaction) do
    case parse_bot_creation_custom_id(interaction.data.custom_id) do
      {:ok, {:accept, requester_snowflake, bot_name}} ->
        handle_bot_creation_accept(requester_snowflake, bot_name, interaction)

      {:ok, {:reject, requester_snowflake, bot_name}} ->
        handle_bot_creation_reject(requester_snowflake, bot_name, interaction)

      {:error, :invalid_custom_id} ->
        send_update_message(interaction, 0xFF6B6B, "❌ Invalid bot creation action.")
    end
  end

  defp send_bot_creation_request(bot_name, interaction) do
    requester_snowflake = interaction.user.id

    requester_display =
      case StackCoin.Core.User.get_user_by_discord_id(requester_snowflake) do
        {:ok, user} -> user.username
        _ -> "#{requester_snowflake}"
      end

    # Send channel reply to the requester
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} Bot Creation Request",
            description:
              "Your request to create bot **#{bot_name}** has been sent for approval. You will be notified when an admin reviews your request.",
            color: Commands.stackcoin_color()
          }
        ]
      }
    })

    # DM the admin with Accept/Reject buttons
    admin_user_id_str = Application.get_env(:stackcoin, :admin_user_id)

    if admin_user_id_str do
      admin_user_id =
        if is_binary(admin_user_id_str),
          do: String.to_integer(admin_user_id_str),
          else: admin_user_id_str

      case Api.User.create_dm(admin_user_id) do
        {:ok, dm_channel} ->
          Api.Message.create(dm_channel.id, %{
            flags: Components.is_components_v2_flag(),
            components: [
              %{
                type: Components.container(),
                accent_color: Commands.stackcoin_color(),
                components: [
                  %{
                    type: Components.text_display(),
                    content:
                      "#{Commands.stackcoin_emoji()} Bot Creation Request\n\n**#{requester_display}** (<@#{requester_snowflake}>) is requesting to create a bot named **#{bot_name}**.\n\nRequester: #{requester_display}\nBot Name: #{bot_name}"
                  },
                  %{
                    type: Components.action_row(),
                    components: [
                      %{
                        type: Components.button(),
                        style: Components.button_style_success(),
                        label: "Accept",
                        custom_id: "bot_create_accept:#{requester_snowflake}:#{bot_name}"
                      },
                      %{
                        type: Components.button(),
                        style: Components.button_style_danger(),
                        label: "Reject",
                        custom_id: "bot_create_reject:#{requester_snowflake}:#{bot_name}"
                      }
                    ]
                  }
                ]
              }
            ]
          })

        {:error, reason} ->
          Logger.error(
            "Failed to DM admin for bot creation request '#{bot_name}': #{inspect(reason)}"
          )

          :error
      end
    end
  end

  defp parse_bot_creation_custom_id("bot_create_" <> rest) do
    case String.split(rest, ":", parts: 3) do
      ["accept", snowflake_str, bot_name] ->
        parse_snowflake(snowflake_str, :accept, bot_name)

      ["reject", snowflake_str, bot_name] ->
        parse_snowflake(snowflake_str, :reject, bot_name)

      _ ->
        {:error, :invalid_custom_id}
    end
  end

  defp parse_bot_creation_custom_id(_), do: {:error, :invalid_custom_id}

  defp parse_snowflake(snowflake_str, action, bot_name) do
    case Integer.parse(snowflake_str) do
      {snowflake, ""} -> {:ok, {action, snowflake, bot_name}}
      _ -> {:error, :invalid_custom_id}
    end
  end

  defp handle_bot_creation_accept(requester_snowflake, bot_name, interaction) do
    case Bot.create_bot_user(requester_snowflake, bot_name) do
      {:ok, bot} ->
        send_update_message(
          interaction,
          0x00FF00,
          "#{Commands.stackcoin_emoji()} Bot Creation Approved\n\nBot **#{bot_name}** has been created for <@#{requester_snowflake}>."
        )

        # DM the requester with their bot token
        send_bot_token_dm(requester_snowflake, bot)

      {:error, %Ecto.Changeset{}} ->
        send_update_message(
          interaction,
          0xFF6B6B,
          "❌ Failed to create bot **#{bot_name}**: a bot with that name may already exist."
        )

      {:error, reason} ->
        send_update_message(
          interaction,
          0xFF6B6B,
          "❌ Failed to create bot **#{bot_name}**: #{inspect(reason)}"
        )
    end
  end

  defp handle_bot_creation_reject(requester_snowflake, bot_name, interaction) do
    send_update_message(
      interaction,
      0xFF0000,
      "#{Commands.stackcoin_emoji()} Bot Creation Denied\n\nBot creation request for **#{bot_name}** from <@#{requester_snowflake}> has been denied."
    )

    # DM the requester about the rejection
    case Api.User.create_dm(requester_snowflake) do
      {:ok, dm_channel} ->
        Api.Message.create(dm_channel.id, %{
          embeds: [
            %{
              title: "#{Commands.stackcoin_emoji()} Bot Creation Request Denied",
              description:
                "Your request to create bot **#{bot_name}** has been denied by an admin.",
              color: 0xFF0000
            }
          ]
        })

      {:error, reason} ->
        Logger.error(
          "Failed to DM requester about bot creation rejection '#{bot_name}': #{inspect(reason)}"
        )

        :error
    end
  end

  defp send_update_message(interaction, color, content) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.update_message(),
      data: %{
        flags: Components.is_components_v2_flag(),
        components: [
          %{
            type: Components.container(),
            accent_color: color,
            components: [
              %{
                type: Components.text_display(),
                content: content
              }
            ]
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
                "Here is the token for your bot **#{bot.name}**:\n\n||#{bot.token}||\n\n**Keep this token secure!** Use it in the `Authorization: Bearer <token>` header for API requests.",
              color: Commands.stackcoin_color()
            }
          ]
        })

      {:error, _reason} ->
        :error
    end
  end
end
