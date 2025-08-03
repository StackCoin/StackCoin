defmodule StackCoin.Bot.Discord.Admin do
  @moduledoc """
  Discord admin command implementation.
  """

  alias StackCoin.Core.{Bank, Reserve}
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
        },
        %{
          type: ApplicationCommandOptionType.sub_command(),
          name: "pump",
          description: "Pump money into the reserve system",
          options: [
            %{
              type: ApplicationCommandOptionType.integer(),
              name: "amount",
              description: "Amount of STK to pump into the reserve",
              required: true,
              min_value: 1
            },
            %{
              type: ApplicationCommandOptionType.string(),
              name: "label",
              description: "Optional label for this pump operation",
              required: false
            }
          ]
        }
      ]
    }
  end

  @doc """
  Handles the admin command interaction.
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

  defp handle_subcommand("register", interaction) do
    guild_id = interaction.guild_id
    channel_id = interaction.channel_id

    if guild_id && channel_id do
      register_channel(guild_id, channel_id, interaction)
    else
      Commands.send_error_response(interaction, "This command must be used in a server channel.")
    end
  end

  defp handle_subcommand("pump", interaction) do
    with {:ok, amount} <- get_pump_amount(interaction),
         {:ok, label} <- get_pump_label(interaction) do
      pump_reserve(amount, label, interaction)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp register_channel(guild_id, channel_id, interaction) do
    case Guild.get(guild_id) do
      {:ok, guild_info} ->
        case Bank.admin_register_guild(interaction.user.id, guild_id, guild_info.name, channel_id) do
          {:ok, {_guild, action}} ->
            send_register_success_response(interaction, action)

          {:error, :not_admin} ->
            Commands.send_error_response(interaction, :not_admin)

          {:error, changeset} ->
            Commands.send_error_response(
              interaction,
              "Failed to register server: #{inspect(changeset.errors)}"
            )
        end

      {:error, _reason} ->
        Commands.send_error_response(
          interaction,
          "Failed to get server information from Discord."
        )
    end
  end

  defp send_register_success_response(interaction, action) do
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
            title: "#{Commands.stackcoin_emoji()} Server #{String.capitalize(action_text)}",
            description:
              "This channel has been #{action_text} as the StackCoin channel for this server.",
            color: Commands.stackcoin_color(),
            fields: [
              %{
                name: "Channel",
                value: "<##{interaction.channel_id}>",
                inline: true
              }
            ]
          }
        ]
      }
    })
  end

  defp get_pump_amount(interaction) do
    case get_option_value(interaction, "amount") do
      nil -> {:error, :missing_amount}
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _ -> {:error, :invalid_amount}
    end
  end

  defp get_pump_label(interaction) do
    case get_option_value(interaction, "label") do
      nil -> {:ok, "Admin pump"}
      label when is_binary(label) -> {:ok, label}
      _ -> {:ok, "Admin pump"}
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

  defp pump_reserve(amount, label, interaction) do
    case Reserve.admin_pump_reserve(interaction.user.id, amount, label) do
      {:ok, pump_record} ->
        send_pump_success_response(interaction, pump_record)

      {:error, :not_admin} ->
        Commands.send_error_response(interaction, :not_admin)

      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp send_pump_success_response(interaction, pump_record) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} Reserve Pumped Successfully!",
            description:
              "**#{pump_record.amount}** STK have been pumped into the reserve system.",
            color: Commands.stackcoin_color(),
            fields: [
              %{
                name: "New Reserve Balance",
                value: "**#{pump_record.to_new_balance}** STK",
                inline: true
              },
              %{
                name: "Label",
                value: pump_record.label,
                inline: true
              }
            ]
          }
        ]
      }
    })
  end
end
