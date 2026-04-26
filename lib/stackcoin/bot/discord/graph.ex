defmodule StackCoin.Bot.Discord.Graph do
  @moduledoc """
  Discord graph command implementation.
  """

  alias StackCoin.Core.{Bank, User, DiscordGuild}
  alias StackCoin.Graph
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType
  alias Nostrum.Constants.ApplicationCommandOptionType

  @doc """
  Returns the command definition for the graph command.
  """
  def definition do
    %{
      name: "graph",
      description: "View StackCoin balances over time",
      options: [
        %{
          type: ApplicationCommandOptionType.user(),
          name: "user",
          description: "User whose balance graph to view",
          required: false
        },
        %{
          type: ApplicationCommandOptionType.string(),
          name: "timerange",
          description: "Time window to show, e.g. 10d, 1hr, 2w (default: all time)",
          required: false
        }
      ]
    }
  end

  @doc """
  Handles the graph command interaction.
  """
  def handle(interaction) do
    with {:ok, guild} <- DiscordGuild.get_guild_by_discord_id(interaction.guild_id),
         {:ok, _channel_check} <- DiscordGuild.validate_channel(guild, interaction.channel_id),
         {:ok, {target_user, is_self}} <- get_target_user(interaction),
         {:ok, since} <- parse_timerange(get_option_value(interaction, "timerange")) do
      opts = if since, do: [since: since], else: []

      with {:ok, history} <- Bank.get_user_balance_history(target_user.id, opts) do
        try do
          png_binary = Graph.generate_balance_chart(history, target_user.username)
          send_graph_response(interaction, png_binary, target_user.username, is_self)
        rescue
          error ->
            Commands.send_error_response(
              interaction,
              "Error creating graph: #{inspect(error)}"
            )
        end
      else
        {:error, reason} ->
          Commands.send_error_response(interaction, reason)
      end
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp get_target_user(interaction) do
    case get_user_option(interaction) do
      nil ->
        # No user specified, check own balance
        case User.get_user_by_discord_id(interaction.user.id) do
          {:ok, user} ->
            case User.check_user_banned(user) do
              {:ok, :not_banned} -> {:ok, {user, true}}
              {:error, :user_banned} -> {:error, :user_banned}
            end

          {:error, reason} ->
            {:error, reason}
        end

      target_user_id ->
        # User specified, check their balance
        case User.get_user_by_discord_id(target_user_id) do
          {:ok, user} -> {:ok, {user, false}}
          {:error, :user_not_found} -> {:error, :other_user_not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp get_option_value(interaction, name) do
    case interaction.data.options do
      nil -> nil
      options ->
        Enum.find_value(options, fn option ->
          if option.name == name, do: option.value, else: nil
        end)
    end
  end

  defp get_user_option(interaction), do: get_option_value(interaction, "user")

  defp send_graph_response(interaction, png_binary, username, is_self) do
    title =
      if is_self do
        "#{Commands.stackcoin_emoji()} Your Balance Over Time"
      else
        "#{Commands.stackcoin_emoji()} #{username}'s Balance Over Time"
      end

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: title,
            color: Commands.stackcoin_color(),
            image: %{
              url: "attachment://balance_chart.png"
            }
          }
        ],
        files: [
          %{
            name: "balance_chart.png",
            body: png_binary
          }
        ]
      }
    })
  end

  @timerange_regex ~r/^\s*(\d+)\s*(m|min|minutes?|h|hr|hours?|d|days?|w|weeks?)\s*$/i

  defp parse_timerange(nil), do: {:ok, nil}

  defp parse_timerange(input) do
    case Regex.run(@timerange_regex, input) do
      [_, amount_str, unit] ->
        amount = String.to_integer(amount_str)
        minutes = unit_to_minutes(String.downcase(unit)) * amount
        since = NaiveDateTime.add(NaiveDateTime.utc_now(), -minutes * 60, :second)
        {:ok, since}

      nil ->
        {:error, "Invalid time range \"#{input}\". Use formats like: 10d, 1hr, 2w, 30m"}
    end
  end

  defp unit_to_minutes(u) when u in ["m", "min", "minute", "minutes"], do: 1
  defp unit_to_minutes(u) when u in ["h", "hr", "hour", "hours"], do: 60
  defp unit_to_minutes(u) when u in ["d", "day", "days"], do: 60 * 24
  defp unit_to_minutes(u) when u in ["w", "week", "weeks"], do: 60 * 24 * 7
end
