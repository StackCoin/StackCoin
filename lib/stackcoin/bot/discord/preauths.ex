defmodule StackCoin.Bot.Discord.Preauths do
  @moduledoc """
  Discord /preauths slash command implementation.
  Subcommands: list, revoke.
  """

  alias StackCoin.Core.{User, Bot, Preauthorization}
  alias StackCoin.Bot.Discord.{Commands, Components}
  alias Nostrum.Api
  alias Nostrum.Constants.{ApplicationCommandOptionType, InteractionCallbackType}

  def definition do
    %{
      name: "preauths",
      description: "Manage your preauthorizations",
      options: [
        %{
          type: ApplicationCommandOptionType.sub_command(),
          name: "list",
          description: "List your active preauthorizations"
        },
        %{
          type: ApplicationCommandOptionType.sub_command(),
          name: "revoke",
          description: "Revoke a bot's preauthorization",
          options: [
            %{
              type: ApplicationCommandOptionType.string(),
              name: "bot",
              description: "Name of the bot whose preauth to revoke",
              required: true
            }
          ]
        }
      ]
    }
  end

  def handle(interaction) do
    discord_id =
      case interaction do
        %{member: %{user: %{id: id}}} when not is_nil(id) -> id
        %{user: %{id: id}} -> id
      end

    case get_subcommand(interaction) do
      {:ok, "list"} ->
        handle_list(discord_id, interaction)

      {:ok, "revoke"} ->
        handle_revoke(discord_id, interaction)

      {:error, :no_subcommand} ->
        Commands.send_error_response(interaction, :no_subcommand)
    end
  end

  defp get_subcommand(interaction) do
    case interaction.data.options do
      [%{name: subcommand_name} | _] -> {:ok, subcommand_name}
      _ -> {:error, :no_subcommand}
    end
  end

  # --- list subcommand ---

  defp handle_list(discord_id, interaction) do
    case User.get_user_by_discord_id(discord_id) do
      {:ok, user} ->
        {:ok, preauths} = Preauthorization.list_preauths_for_user(user.id)
        send_list_response(interaction, preauths)

      {:error, :user_not_found} ->
        Commands.send_error_response(interaction, :user_not_found)
    end
  end

  defp send_list_response(interaction, []) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        flags: Components.is_components_v2_flag(),
        components: [
          %{
            type: Components.container(),
            accent_color: Commands.stackcoin_color(),
            components: [
              %{
                type: Components.text_display(),
                content:
                  "#{Commands.stackcoin_emoji()} Active Preauthorizations\n\nYou have no active preauthorizations."
              }
            ]
          }
        ]
      }
    })
  end

  defp send_list_response(interaction, preauths) do
    preauth_components =
      Enum.map(preauths, fn preauth ->
        bot_name = format_bot_name(preauth.bot_user)
        {:ok, remaining} = Preauthorization.get_remaining_budget(preauth.id)

        %{
          type: Components.text_display(),
          content:
            "**#{bot_name}**\nLimit: #{preauth.max_amount} STK / #{preauth.window_hours}hr\nRemaining: #{remaining}/#{preauth.max_amount} STK"
        }
      end)

    header = %{
      type: Components.text_display(),
      content:
        "#{Commands.stackcoin_emoji()} Active Preauthorizations (#{length(preauths)})"
    }

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        flags: Components.is_components_v2_flag(),
        components: [
          %{
            type: Components.container(),
            accent_color: Commands.stackcoin_color(),
            components: [header | preauth_components]
          }
        ]
      }
    })
  end

  # --- revoke subcommand ---

  defp handle_revoke(discord_id, interaction) do
    bot_name = get_bot_name_option(interaction)

    with {:ok, user} <- User.get_user_by_discord_id(discord_id),
         {:ok, preauths} <- Preauthorization.list_preauths_for_user(user.id),
         {:ok, preauth} <- find_preauth_by_bot_name(preauths, bot_name) do
      case Preauthorization.revoke_preauth(preauth.id) do
        {:ok, _revoked} ->
          send_revoke_success(interaction, format_bot_name(preauth.bot_user))

        {:error, :preauth_not_active} ->
          send_error(interaction, "That preauthorization is not active.")

        {:error, _reason} ->
          send_error(interaction, "Failed to revoke preauthorization.")
      end
    else
      {:error, :user_not_found} ->
        Commands.send_error_response(interaction, :user_not_found)

      {:error, :preauth_not_found} ->
        send_error(
          interaction,
          "No active preauthorization found for a bot named \"#{bot_name}\". Use `/preauths list` to see your active preauths."
        )
    end
  end

  defp get_bot_name_option(interaction) do
    [%{options: options}] = interaction.data.options

    case options do
      [%{name: "bot", value: value} | _] -> value
      _ -> nil
    end
  end

  defp find_preauth_by_bot_name(preauths, bot_name) do
    # Match by the bot's User username (case-insensitive)
    target = String.downcase(bot_name || "")

    case Enum.find(preauths, fn preauth ->
           String.downcase(preauth.bot_user.username) == target
         end) do
      nil -> {:error, :preauth_not_found}
      preauth -> {:ok, preauth}
    end
  end

  defp send_revoke_success(interaction, bot_name) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        flags: Components.is_components_v2_flag(),
        components: [
          %{
            type: Components.container(),
            accent_color: 0x00FF00,
            components: [
              %{
                type: Components.text_display(),
                content:
                  "#{Commands.stackcoin_emoji()} Preauthorization Revoked\n\nThe preauthorization for **#{bot_name}** has been revoked. They can no longer automatically withdraw STK from your account."
              }
            ]
          }
        ]
      }
    })
  end

  defp send_error(interaction, message) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        content: "❌ #{message}"
      }
    })
  end

  # --- helpers ---

  defp format_bot_name(bot_user) do
    case Bot.get_bot_owner_info(bot_user.id) do
      {:ok, {_bot_user, owner_display}} ->
        "#{bot_user.username} (owned by #{owner_display})"

      {:error, :not_bot_user} ->
        bot_user.username
    end
  end
end
