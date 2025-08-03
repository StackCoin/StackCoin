defmodule StackCoin.Bot.Discord.Leaderboard do
  @moduledoc """
  Discord leaderboard command implementation.
  """

  alias StackCoin.Core.Bank
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType

  @doc """
  Returns the command definition for the leaderboard command.
  """
  def definition do
    %{
      name: "leaderboard",
      description: "Show the top 5 StackCoin holders"
    }
  end

  @doc """
  Handles the leaderboard command interaction.
  """
  def handle(interaction) do
    with {:ok, guild} <- Bank.get_guild_by_discord_id(interaction.guild_id),
         {:ok, _channel_check} <- Bank.validate_channel(guild, interaction.channel_id),
         {:ok, top_users} <- Bank.get_top_users(5) do
      send_leaderboard_response(interaction, top_users)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp send_leaderboard_response(interaction, top_users) do
    fields =
      top_users
      |> Enum.with_index(1)
      |> Enum.map(fn {user, rank} ->
        medal = get_medal(rank)

        %{
          name: "##{rank} - #{user.username}: **#{user.balance} STK** #{medal}",
          value: "",
          inline: false
        }
      end)

    embed = %{
      title: "#{Commands.stackcoin_emoji()} StackCoin Leaderboard - Top 5",
      color: Commands.stackcoin_color(),
      fields: fields
    }

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [embed]
      }
    })
  end

  defp get_medal(1), do: "🥇"
  defp get_medal(2), do: "🥈"
  defp get_medal(3), do: "🥉"
  defp get_medal(_), do: ""
end
