defmodule StackCoin.Bot.Discord.Request do
  @moduledoc """
  Discord request notification management for payment requests.
  Handles sending DM notifications with interactive buttons for accept/deny actions.
  """

  alias StackCoin.Core.{Request, User, Bot}
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType

  # Discord Message Components v2 constants
  @is_components_v2_flag 32768
  @container_component 17
  @text_display_component 10
  @action_row_component 1
  @button_component 2
  @button_style_success 3
  @button_style_danger 4

  @doc """
  Sends a DM notification to a Discord user about a payment request.
  Returns :ok if successful, :error if the user is not a Discord user or DM fails.
  """
  def send_request_notification(request) do
    with {:ok, responder_discord} <- get_discord_user(request.responder_id),
         {:ok, requester_name} <- format_requester_info(request.requester) do
      send_request_dm(responder_discord.snowflake, request, requester_name)
    else
      {:error, :not_discord_user} -> :ok
      {:error, _reason} -> :error
    end
  end

  @doc """
  Handles button interactions for request accept/deny actions.
  """
  def handle_request_interaction(interaction) do
    case parse_custom_id(interaction.data.custom_id) do
      {:ok, {action, request_id}} ->
        handle_request_action(action, request_id, interaction)

      {:error, :invalid_custom_id} ->
        send_error_response(interaction, "Invalid request action.")
    end
  end

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

  defp get_user_display_name(user) do
    user = StackCoin.Repo.preload(user, :discord_user)

    case user.discord_user do
      nil -> {:ok, user.username}
      discord_user -> {:ok, "<@#{discord_user.snowflake}>"}
    end
  end

  defp format_requester_info(user) do
    case Bot.get_bot_owner_info(user.id) do
      {:ok, {_bot_user, owner_display}} ->
        {:ok, "#{user.username} (bot owned by #{owner_display})"}

      {:error, :not_bot_user} ->
        get_user_display_name(user)
    end
  end

  defp send_request_dm(user_snowflake, request, requester_name) do
    user_id = String.to_integer(user_snowflake)

    case Api.User.create_dm(user_id) do
      {:ok, dm_channel} ->
        amount_display = format_amount(request.amount)
        label_text = if request.label, do: " for \"#{request.label}\"", else: ""
        label_info = if request.label, do: "\nLabel: #{request.label}", else: ""

        components = [
          %{
            type: @container_component,
            accent_color: Commands.stackcoin_color(),
            components: [
              %{
                type: @text_display_component,
                content:
                  "#{Commands.stackcoin_emoji()} Payment Request\n\n#{requester_name} is requesting #{amount_display} STK from you#{label_text}.\n\nAmount: #{amount_display} STK\nFrom: #{requester_name}#{label_info}\nRequest ID: #{request.id}"
              },
              %{
                type: @action_row_component,
                components: [
                  %{
                    type: @button_component,
                    style: @button_style_success,
                    label: "Accept",
                    custom_id: "request_accept_#{request.id}"
                  },
                  %{
                    type: @button_component,
                    style: @button_style_danger,
                    label: "Deny",
                    custom_id: "request_deny_#{request.id}"
                  }
                ]
              }
            ]
          }
        ]

        case Api.Message.create(dm_channel.id, %{
               flags: @is_components_v2_flag,
               components: components
             }) do
          {:ok, _message} -> :ok
          {:error, _reason} -> :error
        end

      {:error, _reason} ->
        :error
    end
  end

  def parse_custom_id("request_accept_" <> request_id_str) do
    case Integer.parse(request_id_str) do
      {request_id, ""} -> {:ok, {:accept, request_id}}
      _ -> {:error, :invalid_custom_id}
    end
  end

  def parse_custom_id("request_deny_" <> request_id_str) do
    case Integer.parse(request_id_str) do
      {request_id, ""} -> {:ok, {:deny, request_id}}
      _ -> {:error, :invalid_custom_id}
    end
  end

  def parse_custom_id(_), do: {:error, :invalid_custom_id}

  defp handle_request_action(:accept, request_id, interaction) do
    with {:ok, user} <- User.get_user_by_discord_id(interaction.user.id) do
      case Request.accept_request(request_id, user.id) do
        {:ok, request} ->
          send_accept_success_response(interaction, request)

        {:error, :request_not_found} ->
          send_error_response(interaction, "Request not found.")

        {:error, :not_request_responder} ->
          send_error_response(interaction, "You are not authorized to accept this request.")

        {:error, :request_not_pending} ->
          send_error_response(interaction, "This request is no longer pending.")

        {:error, :insufficient_balance} ->
          send_retryable_error_response(
            interaction,
            "You don't have enough STK to fulfill this request."
          )

        {:error, reason} ->
          send_error_response(interaction, "Failed to accept request: #{inspect(reason)}")
      end
    else
      {:error, :user_not_found} ->
        send_error_response(interaction, "You don't have a StackCoin account.")

      {:error, reason} ->
        send_error_response(interaction, "Failed to get user: #{inspect(reason)}")
    end
  end

  defp handle_request_action(:deny, request_id, interaction) do
    with {:ok, user} <- User.get_user_by_discord_id(interaction.user.id) do
      case Request.deny_request(request_id, user.id) do
        {:ok, request} ->
          send_deny_success_response(interaction, request)

        {:error, :request_not_found} ->
          send_error_response(interaction, "Request not found.")

        {:error, :not_involved_in_request} ->
          send_error_response(interaction, "You are not authorized to deny this request.")

        {:error, :request_not_pending} ->
          send_error_response(interaction, "This request is no longer pending.")

        {:error, reason} ->
          send_error_response(interaction, "Failed to deny request: #{inspect(reason)}")
      end
    else
      {:error, :user_not_found} ->
        send_error_response(interaction, "You don't have a StackCoin account.")

      {:error, reason} ->
        send_error_response(interaction, "Failed to get user: #{inspect(reason)}")
    end
  end

  defp send_accept_success_response(interaction, request) do
    amount_display = format_amount(request.amount)
    requester_name = format_requester_info(request.requester) |> elem(1)
    label_info = if request.label, do: "\nLabel: #{request.label}", else: ""

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.update_message(),
      data: %{
        flags: @is_components_v2_flag,
        components: [
          %{
            type: @container_component,
            # Green for success
            accent_color: 0x00FF00,
            components: [
              %{
                type: @text_display_component,
                content:
                  "#{Commands.stackcoin_emoji()} Request Accepted\n\nYou have successfully sent #{amount_display} STK to #{requester_name}.\n\nAmount: #{amount_display} STK\nTo: #{requester_name}#{label_info}\nTransaction ID: #{request.transaction_id}"
              }
            ]
          }
        ]
      }
    })
  end

  defp send_deny_success_response(interaction, request) do
    amount_display = format_amount(request.amount)
    requester_name = format_requester_info(request.requester) |> elem(1)
    label_info = if request.label, do: "\nLabel: #{request.label}", else: ""

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.update_message(),
      data: %{
        flags: @is_components_v2_flag,
        components: [
          %{
            type: @container_component,
            # Red for denial
            accent_color: 0xFF0000,
            components: [
              %{
                type: @text_display_component,
                content:
                  "#{Commands.stackcoin_emoji()} Request Denied\n\nYou have denied the request for #{amount_display} STK from #{requester_name}.\n\nAmount: #{amount_display} STK\nFrom: #{requester_name}#{label_info}"
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
        flags: @is_components_v2_flag,
        components: [
          %{
            type: @container_component,
            # Light red for errors
            accent_color: 0xFF6B6B,
            components: [
              %{
                type: @text_display_component,
                content: "❌ #{message}"
              }
            ]
          }
        ]
      }
    })
  end

  defp send_retryable_error_response(interaction, error_message) do
    # Extract request ID from the interaction to get original request details
    case parse_custom_id(interaction.data.custom_id) do
      {:ok, {_action, request_id}} ->
        case Request.get_request_by_id(request_id) do
          {:ok, request} ->
            {:ok, requester_name} = format_requester_info(request.requester)
            amount_display = format_amount(request.amount)
            label_text = if request.label, do: " for \"#{request.label}\"", else: ""
            label_info = if request.label, do: "\nLabel: #{request.label}", else: ""

            Api.create_interaction_response(interaction, %{
              type: InteractionCallbackType.update_message(),
              data: %{
                flags: @is_components_v2_flag,
                components: [
                  %{
                    type: @container_component,
                    # Light red for errors
                    accent_color: 0xFF6B6B,
                    components: [
                      %{
                        type: @text_display_component,
                        content:
                          "❌ #{error_message}\n\n#{Commands.stackcoin_emoji()} Original Request\n#{requester_name} is requesting #{amount_display} STK from you#{label_text}.\n\nAmount: #{amount_display} STK\nFrom: #{requester_name}#{label_info}\nRequest ID: #{request.id}"
                      },
                      %{
                        type: @action_row_component,
                        components: [
                          %{
                            type: @button_component,
                            style: @button_style_success,
                            label: "Try Again",
                            custom_id: "request_accept_#{request.id}"
                          },
                          %{
                            type: @button_component,
                            style: @button_style_danger,
                            label: "Deny",
                            custom_id: "request_deny_#{request.id}"
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            })

          {:error, _reason} ->
            send_error_response(interaction, error_message)
        end

      {:error, _reason} ->
        send_error_response(interaction, error_message)
    end
  end

  defp format_amount(amount) do
    to_string(amount)
  end
end
