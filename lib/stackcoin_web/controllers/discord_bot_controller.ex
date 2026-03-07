defmodule StackCoinWeb.DiscordBotController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  operation :show,
    operation_id: "stackcoin_discord_bot",
    summary: "Get the StackCoin Discord bot",
    description: "Returns the Discord user ID of the StackCoin bot that sends DMs.",
    responses: [
      ok: {"Discord bot response", "application/json", StackCoinWeb.Schemas.DiscordBotResponse},
      service_unavailable:
        {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

  def show(conn, _params) do
    case Nostrum.Cache.Me.get() do
      %{id: id} ->
        json(conn, %{discord_id: Integer.to_string(id)})

      nil ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Discord bot not connected"})
    end
  end
end
