defmodule StackCoin.Bot.Discord do
  use Nostrum.Consumer

  alias Nostrum.Api
  alias Nostrum.Struct.Interaction
  alias Nostrum.Constants.InteractionCallbackType

  alias StackCoin.Bot.Discord.{Balance, Admin, Dole, Send, Leaderboard, Transactions}

  def handle_event(
        {:INTERACTION_CREATE, %Interaction{data: %{name: name}} = interaction, _ws_state}
      ) do
    handle_slash_command(name, interaction)
  end

  def handle_event(_), do: :ok

  defp handle_slash_command("balance", interaction) do
    Balance.handle(interaction)
  end

  defp handle_slash_command("admin", interaction) do
    Admin.handle(interaction)
  end

  defp handle_slash_command("dole", interaction) do
    Dole.handle(interaction)
  end

  defp handle_slash_command("send", interaction) do
    Send.handle(interaction)
  end

  defp handle_slash_command("leaderboard", interaction) do
    Leaderboard.handle(interaction)
  end

  defp handle_slash_command("transactions", interaction) do
    Transactions.handle(interaction)
  end

  defp handle_slash_command(command_name, interaction) do
    response = %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        content: "Unknown command: #{command_name}"
      }
    }

    Api.Interaction.create_response(interaction, response)
  end
end
