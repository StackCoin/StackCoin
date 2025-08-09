defmodule StackCoinWeb.Plugs.BotAuth do
  @moduledoc """
  Plug for authenticating bot users via Bearer tokens.
  """

  import Plug.Conn
  alias StackCoin.Core.Bot

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        authenticate_bot(conn, token)

      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "Missing or invalid Authorization header"})
        |> halt()
    end
  end

  defp authenticate_bot(conn, token) do
    case Bot.get_bot_by_token(token) do
      {:ok, bot} ->
        conn
        |> assign(:current_bot, bot)
        |> assign(:current_user, bot.user)
        |> assign(:bot_owner, bot.owner)

      {:error, :invalid_token} ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "Invalid bot token"})
        |> halt()
    end
  end
end
