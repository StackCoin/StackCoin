defmodule StackCoin.Bot.Discord.Graph do
  @moduledoc """
  Discord graph command implementation.
  """

  alias VegaLite, as: Vl
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType

  @doc """
  Returns the command definition for the graph command.
  """
  def definition do
    %{
      name: "graph",
      description: "Generate a sample VegaLite graph"
    }
  end

  @doc """
  Handles the graph command interaction.
  """
  def handle(interaction) do
    try do
      vl =
        Vl.new(width: 400, height: 400)
        |> Vl.data_from_values(iteration: 1..100, score: 1..100)
        |> Vl.mark(:line)
        |> Vl.encode_field(:x, "iteration", type: :quantitative)
        |> Vl.encode_field(:y, "score", type: :quantitative)

      png_binary = VegaLite.Convert.to_png(vl)
      send_graph_response(interaction, png_binary)
    rescue
      error ->
        Commands.send_error_response(interaction, "Error creating graph: #{inspect(error)}")
    end
  end

  defp send_graph_response(interaction, png_binary) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} Sample Graph",
            color: Commands.stackcoin_color(),
            image: %{
              url: "attachment://graph.png"
            }
          }
        ],
        files: [
          %{
            name: "graph.png",
            body: png_binary
          }
        ]
      }
    })
  end
end
