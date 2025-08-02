defmodule StackCoin.Bot.Discord do
  use Nostrum.Consumer

  alias Nostrum.Api
  alias Nostrum.Struct.Interaction

  def handle_event(
        {:INTERACTION_CREATE, %Interaction{data: %{name: name}} = interaction, _ws_state}
      ) do
    handle_slash_command(name, interaction)
  end

  def handle_event(_), do: :ok

  defp handle_slash_command("hello", interaction) do
    response = %{
      type: 4,
      data: %{
        content: "Hello there! 👋"
      }
    }

    Api.Interaction.create_response(interaction, response)
  end

  defp handle_slash_command("ping", interaction) do
    response = %{
      type: 4,
      data: %{
        content: "Pong! 🏓"
      }
    }

    Api.Interaction.create_response(interaction, response)
  end

  defp handle_slash_command(command_name, interaction) do
    response = %{
      type: 4,
      data: %{
        content: "Unknown command: #{command_name}",
        flags: 64
      }
    }

    Api.Interaction.create_response(interaction, response)
  end
end
