defmodule StackCoin.Bot.Discord.Admin do
  @moduledoc """
  Discord admin command implementation.
  """

  alias StackCoin.Core.Bank
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Api.Guild
  alias Nostrum.Constants.{ApplicationCommandOptionType, InteractionCallbackType}

  @doc """
  Returns the command definition for the admin command.
  """
  def definition do
    %{
      name: "admin",
      description: "Admin commands for StackCoin",
      options: [
        %{
          type: ApplicationCommandOptionType.sub_command(),
          name: "register",
          description: "Register this channel as the StackCoin channel for this server"
        }
      ]
    }
  end

  @doc """
  Handles the admin command interaction.
  """
  def handle(interaction) do
    with {:ok, _admin_check} <- check_admin_permissions(interaction.user.id),
         {:ok, subcommand} <- get_subcommand(interaction) do
      handle_subcommand(subcommand, interaction)
    else
      {:error, :not_admin} ->
        Api.create_interaction_response(interaction, %{
          type: InteractionCallbackType.channel_message_with_source(),
          data: %{
            content: "❌ You don't have permission to use admin commands."
          }
        })

      {:error, reason} ->
        Api.create_interaction_response(interaction, %{
          type: InteractionCallbackType.channel_message_with_source(),
          data: %{
            content: "❌ An error occurred: #{inspect(reason)}"
          }
        })
    end
  end

  defp check_admin_permissions(user_snowflake) do
    admin_user_id = Application.get_env(:stackcoin, :admin_user_id)
    user_snowflake_str = to_string(user_snowflake)

    cond do
      admin_user_id && user_snowflake_str == admin_user_id ->
        ensure_admin_user_exists(user_snowflake_str)
        {:ok, :admin}

      true ->
        case Bank.is_user_admin?(user_snowflake_str) do
          {:ok, true} -> {:ok, :admin}
          {:ok, false} -> {:error, :not_admin}
          {:error, :user_not_found} -> {:error, :not_admin}
        end
    end
  end

  defp ensure_admin_user_exists(user_snowflake) do
    case Bank.get_user_by_discord_id(user_snowflake) do
      {:ok, _user} ->
        :ok

      {:error, :user_not_found} ->
        case Api.User.get(String.to_integer(user_snowflake)) do
          {:ok, discord_user} ->
            case Bank.create_user_account(user_snowflake, discord_user.username, admin: true) do
              {:ok, _user} -> :ok
              {:error, _} -> :error
            end

          {:error, _} ->
            case Bank.create_user_account(user_snowflake, "Admin User", admin: true) do
              {:ok, _user} -> :ok
              {:error, _} -> :error
            end
        end
    end
  end

  defp get_subcommand(interaction) do
    case interaction.data.options do
      [%{name: subcommand_name} | _] -> {:ok, subcommand_name}
      _ -> {:error, :no_subcommand}
    end
  end

  defp handle_subcommand("register", interaction) do
    guild_id = interaction.guild_id
    channel_id = interaction.channel_id

    if guild_id && channel_id do
      register_channel(guild_id, channel_id, interaction)
    else
      Api.create_interaction_response(interaction, %{
        type: InteractionCallbackType.channel_message_with_source(),
        data: %{
          content: "❌ This command must be used in a server channel."
        }
      })
    end
  end

  defp register_channel(guild_id, channel_id, interaction) do
    case Guild.get(guild_id) do
      {:ok, guild_info} ->
        case Bank.register_guild(guild_id, guild_info.name, channel_id) do
          {:ok, {_guild, action}} ->
            send_success_response(interaction, action)

          {:error, changeset} ->
            send_error_response(
              interaction,
              "Failed to register server: #{inspect(changeset.errors)}"
            )
        end

      {:error, _reason} ->
        send_error_response(interaction, "Failed to get server information from Discord.")
    end
  end

  defp send_success_response(interaction, action) do
    action_text =
      case action do
        :created -> "registered"
        :updated -> "updated"
      end

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "✅ Server #{String.capitalize(action_text)}",
            description:
              "This channel has been #{action_text} as the StackCoin channel for this server.",
            color: Commands.stackcoin_color()
          }
        ]
      }
    })
  end

  defp send_error_response(interaction, message) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        content: "❌ #{message}"
      }
    })
  end
end
