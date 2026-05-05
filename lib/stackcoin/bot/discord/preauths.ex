defmodule StackCoin.Bot.Discord.Preauths do
  @moduledoc """
  Discord /preauths slash command implementation.
  Lists the user's active preauthorizations with revoke buttons.
  """

  alias StackCoin.Core.{User, Bot, Preauthorization}
  alias StackCoin.Bot.Discord.{Commands, Components}
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType

  def definition do
    %{
      name: "preauths",
      description: "List your active preauthorizations",
      type: 1
    }
  end

  def handle(interaction) do
    discord_id =
      case interaction do
        %{member: %{user: %{id: id}}} when not is_nil(id) -> id
        %{user: %{id: id}} -> id
      end

    case User.get_user_by_discord_id(discord_id) do
      {:ok, user} ->
        {:ok, preauths} = Preauthorization.list_preauths_for_user(user.id)
        send_preauths_response(interaction, preauths)

      {:error, :user_not_found} ->
        Commands.send_error_response(interaction, :user_not_found)
    end
  end

  defp send_preauths_response(interaction, []) do
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

  defp send_preauths_response(interaction, preauths) do
    preauth_components =
      Enum.flat_map(preauths, fn preauth ->
        bot_name = format_bot_name(preauth.bot_user)
        {:ok, remaining} = Preauthorization.get_remaining_budget(preauth.id)

        [
          %{
            type: Components.text_display(),
            content:
              "**#{bot_name}**\nLimit: #{preauth.max_amount} STK / #{preauth.window_hours}hr\nRemaining: #{remaining}/#{preauth.max_amount} STK"
          },
          %{
            type: Components.action_row(),
            components: [
              %{
                type: Components.button(),
                style: Components.button_style_danger(),
                label: "Revoke",
                custom_id: "preauth_revoke_#{preauth.id}"
              }
            ]
          }
        ]
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

  defp format_bot_name(bot_user) do
    case Bot.get_bot_owner_info(bot_user.id) do
      {:ok, {_bot_user, owner_display}} ->
        "#{bot_user.username} (owned by #{owner_display})"

      {:error, :not_bot_user} ->
        bot_user.username
    end
  end
end
