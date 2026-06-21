defmodule StackCoin.Bot.Discord.Preauth do
  @moduledoc """
  Discord preauthorization notification management.
  Handles sending DM notifications with interactive buttons for accept/deny/revoke actions.
  """

  alias StackCoin.Core.{User, Bot, Preauthorization}
  alias StackCoin.Bot.Discord.Commands
  alias StackCoin.Bot.Discord.Components
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType

  @doc """
  Sends a DM notification to a Discord user about a new preauthorization request.
  Returns :ok if successful, :error if the user is not a Discord user or DM fails.
  """
  def send_preauth_notification(preauth) do
    if Application.get_env(:stackcoin, :start_discord, true) do
      with {:ok, responder_discord} <- get_discord_user(preauth.user_id),
           {:ok, bot_name} <- format_bot_name(preauth.bot_user) do
        send_preauth_dm(responder_discord.snowflake, preauth, bot_name)
      else
        {:error, :not_discord_user} -> :ok
        {:error, _reason} -> :error
      end
    else
      :ok
    end
  end

  @doc """
  Sends a DM notification to a Discord user about a preauth transfer.
  Takes a request (with preloaded preauthorization) and remaining_budget integer.
  """
  def send_preauth_transfer_notification(request, remaining_budget) do
    if Application.get_env(:stackcoin, :start_discord, true) do
      preauth = request.preauthorization

      with {:ok, responder_discord} <- get_discord_user(preauth.user_id),
           {:ok, bot_name} <- format_bot_name(preauth.bot_user) do
        send_transfer_dm(
          responder_discord.snowflake,
          request,
          preauth,
          bot_name,
          remaining_budget
        )
      else
        {:error, :not_discord_user} -> :ok
        {:error, _reason} -> :error
      end
    else
      :ok
    end
  end

  @doc """
  Handles button interactions for preauth accept/deny/revoke actions.
  """
  def handle_preauth_interaction(interaction) do
    case parse_custom_id(interaction.data.custom_id) do
      {:ok, {action, preauth_id}} ->
        handle_preauth_action(action, preauth_id, interaction)

      {:error, :invalid_custom_id} ->
        send_error_response(interaction, "Invalid preauthorization action.")
    end
  end

  def parse_custom_id("preauth_accept_" <> id_str), do: parse_id(id_str, :accept)
  def parse_custom_id("preauth_deny_" <> id_str), do: parse_id(id_str, :deny)
  def parse_custom_id("preauth_revoke_" <> id_str), do: parse_id(id_str, :revoke)
  def parse_custom_id(_), do: {:error, :invalid_custom_id}

  defp parse_id(id_str, action) do
    case Integer.parse(id_str) do
      {id, ""} -> {:ok, {action, id}}
      _ -> {:error, :invalid_custom_id}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp get_discord_user(user_id) do
    case User.get_user_by_id(user_id) do
      {:ok, user} ->
        user = StackCoin.Repo.preload(user, :discord_user)

        case user.discord_user do
          nil -> {:error, :not_discord_user}
          discord_user -> {:ok, discord_user}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_bot_name(bot_user) do
    case Bot.get_bot_owner_info(bot_user.id) do
      {:ok, {_bot_user, owner_display}} ->
        {:ok, "#{bot_user.username} (bot owned by #{owner_display})"}

      {:error, :not_bot_user} ->
        {:ok, bot_user.username}
    end
  end

  defp send_preauth_dm(user_snowflake, preauth, bot_name) do
    user_id = String.to_integer(user_snowflake)

    case Api.User.create_dm(user_id) do
      {:ok, dm_channel} ->
        components = [
          %{
            type: Components.container(),
            accent_color: Commands.stackcoin_color(),
            components: [
              %{
                type: Components.text_display(),
                content:
                  "#{Commands.stackcoin_emoji()} Preauthorization Request\n\n#{bot_name} wants permission to automatically withdraw up to #{preauth.max_amount} STK every #{preauth.window_hours} hours.\n\nThis means the bot can take STK from your account without asking each time, up to the limit shown above.\n\nYou can revoke this at any time."
              },
              %{
                type: Components.action_row(),
                components: [
                  %{
                    type: Components.button(),
                    style: Components.button_style_success(),
                    label: "Accept",
                    custom_id: "preauth_accept_#{preauth.id}"
                  },
                  %{
                    type: Components.button(),
                    style: Components.button_style_danger(),
                    label: "Deny",
                    custom_id: "preauth_deny_#{preauth.id}"
                  }
                ]
              }
            ]
          }
        ]

        case Api.Message.create(dm_channel.id, %{
               flags: Components.is_components_v2_flag(),
               components: components
             }) do
          {:ok, _message} -> :ok
          {:error, _reason} -> :error
        end

      {:error, _reason} ->
        :error
    end
  end

  defp send_transfer_dm(user_snowflake, request, preauth, bot_name, remaining_budget) do
    user_id = String.to_integer(user_snowflake)

    case Api.User.create_dm(user_id) do
      {:ok, dm_channel} ->
        label_text = if request.label, do: "\nLabel: #{request.label}", else: ""

        components = [
          %{
            type: Components.container(),
            accent_color: Commands.stackcoin_color(),
            components: [
              %{
                type: Components.text_display(),
                content:
                  "#{Commands.stackcoin_emoji()} #{bot_name} withdrew #{request.amount} STK#{label_text}\nNew Balance: #{request.responder_new_balance} STK\nBudget remaining: #{remaining_budget}/#{preauth.max_amount} STK (#{preauth.window_hours}hr)"
              },
              %{
                type: Components.action_row(),
                components: [
                  %{
                    type: Components.button(),
                    style: Components.button_style_danger(),
                    label: "Revoke Preauth",
                    custom_id: "preauth_revoke_#{preauth.id}"
                  }
                ]
              }
            ]
          }
        ]

        case Api.Message.create(dm_channel.id, %{
               flags: Components.is_components_v2_flag(),
               components: components
             }) do
          {:ok, _message} -> :ok
          {:error, _reason} -> :error
        end

      {:error, _reason} ->
        :error
    end
  end

  defp handle_preauth_action(action, preauth_id, interaction) do
    with {:ok, preauth} <- Preauthorization.get_preauth(preauth_id),
         :ok <- validate_preauth_owner(preauth, interaction) do
      execute_preauth_action(action, preauth, interaction)
    else
      {:error, :preauth_not_found} ->
        send_error_response(interaction, "Preauthorization not found.")

      {:error, :not_preauth_owner} ->
        send_error_response(
          interaction,
          "You are not authorized to manage this preauthorization."
        )
    end
  end

  defp validate_preauth_owner(preauth, interaction) do
    discord_id = interaction.user.id

    case User.get_user_by_discord_id(discord_id) do
      {:ok, user} when user.id == preauth.user_id -> :ok
      _ -> {:error, :not_preauth_owner}
    end
  end

  defp execute_preauth_action(:accept, preauth, interaction) do
    case Preauthorization.approve_preauth(preauth.id) do
      {:ok, approved} ->
        send_accept_success_response(interaction, approved)

      {:error, :preauth_not_pending} ->
        send_error_response(interaction, "This preauthorization is no longer pending.")

      {:error, reason} ->
        send_error_response(interaction, "Failed to accept preauthorization: #{inspect(reason)}")
    end
  end

  defp execute_preauth_action(:deny, preauth, interaction) do
    case Preauthorization.delete_preauth(preauth.id) do
      {:ok, _preauth} ->
        send_deny_success_response(interaction)

      {:error, :preauth_not_pending} ->
        send_error_response(interaction, "This preauthorization is no longer pending.")

      {:error, reason} ->
        send_error_response(interaction, "Failed to deny preauthorization: #{inspect(reason)}")
    end
  end

  defp execute_preauth_action(:revoke, preauth, interaction) do
    case Preauthorization.revoke_preauth(preauth.id) do
      {:ok, _preauth} ->
        send_revoke_success_response(interaction)

      {:error, :preauth_not_active} ->
        send_error_response(interaction, "This preauthorization is not active.")

      {:error, reason} ->
        send_error_response(interaction, "Failed to revoke preauthorization: #{inspect(reason)}")
    end
  end

  defp send_accept_success_response(interaction, preauth) do
    {:ok, bot_name} = format_bot_name(preauth.bot_user)

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.update_message(),
      data: %{
        flags: Components.is_components_v2_flag(),
        components: [
          %{
            type: Components.container(),
            # Green for success
            accent_color: 0x00FF00,
            components: [
              %{
                type: Components.text_display(),
                content:
                  "#{Commands.stackcoin_emoji()} Preauthorization Active\n\n#{bot_name} can now withdraw up to #{preauth.max_amount} STK every #{preauth.window_hours} hours.\n\nYou can revoke this at any time with `/preauths`."
              }
            ]
          }
        ]
      }
    })
  end

  defp send_deny_success_response(interaction) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.update_message(),
      data: %{
        flags: Components.is_components_v2_flag(),
        components: [
          %{
            type: Components.container(),
            # Red for denial
            accent_color: 0xFF0000,
            components: [
              %{
                type: Components.text_display(),
                content:
                  "#{Commands.stackcoin_emoji()} Preauthorization Declined\n\nYou have declined this preauthorization request."
              }
            ]
          }
        ]
      }
    })
  end

  defp send_revoke_success_response(interaction) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.update_message(),
      data: %{
        flags: Components.is_components_v2_flag(),
        components: [
          %{
            type: Components.container(),
            # Red for revoked
            accent_color: 0xFF0000,
            components: [
              %{
                type: Components.text_display(),
                content:
                  "#{Commands.stackcoin_emoji()} Preauthorization Revoked\n\nThis preauthorization has been revoked. The bot can no longer withdraw STK from your account."
              }
            ]
          }
        ]
      }
    })
  end

  defp send_error_response(interaction, message) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.update_message(),
      data: %{
        flags: Components.is_components_v2_flag(),
        components: [
          %{
            type: Components.container(),
            # Light red for errors
            accent_color: 0xFF6B6B,
            components: [
              %{
                type: Components.text_display(),
                content: "❌ #{message}"
              }
            ]
          }
        ]
      }
    })
  end
end
